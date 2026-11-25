"""Randomized accounting stress test on real file systems (opt-in, not CI).

Creates a disk image per file system, fills it with a random mix of files,
sparse files, hard links, APFS clones (of files and whole folders), edits,
moves and deletes, while a model tracks which paths share one data stream.
Then checks the CLI against that model, exactly:

- allocated bytes = the sum over live data streams of one member's
  allocation (hard links and whole clones count once, edited clones count
  in full), and the same for logical bytes;
- every path is listed (file_count);
- with no edited clones, the scan never exceeds the volume's used space;
- repeated scans are identical byte for byte (owner choice does not depend
  on thread scheduling), checked with the bench binary's digest mode.

Usage: python3 tests/stress_clones.py [--seeds 1 2 3] [--ops 300]
Needs hdiutil (no root). Build first: cargo build --release --features cli
and cargo build --release --bin bench.
"""
import argparse
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("BLITZTREE_BIN", ROOT / "target/release/blitztree"))
BENCH = Path(os.environ.get("BLITZTREE_BENCH", ROOT / "target/release/bench"))
FILESYSTEMS = {
    # name: (hdiutil -fs, clones, hard links, exotic names)
    "apfs": ("APFS", True, True, True),
    "apfs-cs": ("Case-sensitive APFS", True, True, True),
    "hfs": ("HFS+", False, True, True),
    "exfat": ("ExFAT", False, False, False),
    "fat32": ("MS-DOS FAT32", False, False, False),
}


class Model:
    """paths -> inode -> data stream. Clones share a stream across inodes,
    hard links share an inode; editing a shared stream forks the inode off."""

    def __init__(self):
        self.path_inode = {}
        self.inode_stream = {}
        self.next = 0

    def fresh(self):
        self.next += 1
        return self.next

    def add_file(self, path):
        inode = self.fresh()
        self.inode_stream[inode] = self.fresh()
        self.path_inode[path] = inode

    def clone(self, src, dst):
        inode = self.fresh()
        self.inode_stream[inode] = self.inode_stream[self.path_inode[src]]
        self.path_inode[dst] = inode

    def link(self, src, dst):
        self.path_inode[dst] = self.path_inode[src]

    def edit(self, path):
        inode = self.path_inode[path]
        stream = self.inode_stream[inode]
        if sum(1 for s in self.inode_stream.values() if s == stream) > 1:
            self.inode_stream[inode] = self.fresh()
            return True
        return False

    def remove(self, path):
        inode = self.path_inode.pop(path)
        if inode not in self.path_inode.values():
            del self.inode_stream[inode]

    def move(self, src, dst):
        self.path_inode[dst] = self.path_inode.pop(src)

    def streams(self):
        """One representative path per live data stream."""
        out = {}
        for path, inode in sorted(self.path_inode.items()):
            out.setdefault(self.inode_stream[inode], path)
        return out


def sh(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw)


def name(rng, exotic):
    base = rng.choice(["a", "b", "data", "Ünïcödé", "日本", "with space", "x.y"] if exotic else ["a", "b", "data", "x"])
    return f"{base}-{rng.randrange(1 << 30):08x}"


def populate(mnt, rng, ops, clones, links, exotic, edits):
    model, dirs, edited_clone = Model(), [mnt], False
    for _ in range(ops):
        files = sorted(model.path_inode)
        op = rng.choices(
            ["mkdir", "file", "sparse", "clone", "clonedir", "link", "edit", "rm", "mv"],
            [6, 20, 4, 18 if clones else 0, 3 if clones else 0, 10 if links else 0, 8 if edits else 0, 6, 5],
        )[0]
        if op == "mkdir" or (op in ("clone", "link", "edit", "rm", "mv") and not files):
            d = rng.choice(dirs) / name(rng, exotic)
            d.mkdir()
            dirs.append(d)
        elif op in ("file", "sparse"):
            p = rng.choice(dirs) / name(rng, exotic)
            with open(p, "wb") as f:
                if op == "sparse":
                    f.seek(rng.randrange(1 << 20, 64 << 20))
                f.write(os.urandom(rng.choice([0, 1, 4095, 4096, 70_000, 1 << 20, 3 << 20])))
            model.add_file(p)
        elif op == "clone":
            src = Path(rng.choice(files))
            dst = rng.choice(dirs) / name(rng, exotic)
            sh("cp", "-c", str(src), str(dst))
            model.clone(src, dst)
        elif op == "clonedir":
            src = rng.choice(dirs[1:] or dirs)
            if src == mnt:
                continue
            dst = src.parent / name(rng, exotic)
            sh("cp", "-c", "-R", str(src), str(dst))
            for p in sorted(model.path_inode):
                if Path(p).is_relative_to(src):
                    model.clone(p, dst / Path(p).relative_to(src))
            for d in list(dirs):
                if d.is_relative_to(src):
                    dirs.append(dst / d.relative_to(src))
        elif op == "link":
            src = Path(rng.choice(files))
            dst = rng.choice(dirs) / name(rng, exotic)
            os.link(src, dst)
            model.link(src, dst)
        elif op == "edit":
            p = Path(rng.choice(files))
            with open(p, "r+b") as f:
                size = f.seek(0, 2)
                f.seek(rng.randrange(size + 1))
                f.write(os.urandom(rng.choice([1, 5000, 1 << 16])))
            edited_clone |= model.edit(p)
        elif op == "rm":
            p = Path(rng.choice(files))
            p.unlink()
            model.remove(p)
        elif op == "mv":
            src = Path(rng.choice(files))
            dst = rng.choice(dirs) / name(rng, exotic)
            src.rename(dst)
            model.move(src, dst)
    sh("sync")
    return model, edited_clone


def check(fs, seed, ops, work, edits=True):
    hdi_fs, clones, links, exotic = FILESYSTEMS[fs]
    image, mnt = work / f"{fs}-{seed}.sparseimage", work / f"mnt-{fs}-{seed}"
    sh("hdiutil", "create", "-size", "4g", "-type", "SPARSE", "-fs", hdi_fs, "-volname", "BZS", str(image.with_suffix("")))
    mnt.mkdir()
    sh("hdiutil", "attach", "-nobrowse", "-noverify", "-mountpoint", str(mnt), str(image))
    try:
        rng = random.Random(f"{fs}-{seed}")
        model, edited_clone = populate(mnt, rng, ops, clones, links, exotic, edits)
        streams = model.streams()
        stat = {s: os.lstat(p) for s, p in streams.items()}
        expected_alloc = sum(st.st_blocks * 512 for st in stat.values())
        expected_logical = sum(st.st_size for st in stat.values())
        report = json.loads(sh(str(CLI), "scan", "--root", str(mnt), "--min-bytes", "1", "--limit", "1").stdout)
        modelled = {unicodedata.normalize("NFC", str(p)) for p in model.path_inode}
        extra = [p for p in mnt.rglob("*") if p.is_file() and not p.is_symlink()
                 and unicodedata.normalize("NFC", str(p)) not in modelled and "HFS+ Private" not in str(p)]
        extra_alloc = sum(p.lstat().st_blocks * 512 for p in extra)
        extra_logical = sum(p.lstat().st_size for p in extra)
        got = report["summary"]
        problems = []
        if got["allocated_bytes"] != expected_alloc + extra_alloc:
            problems.append(f"allocated {got['allocated_bytes']} != model {expected_alloc} + unmodelled {extra_alloc}")
        if got["logical_bytes"] != expected_logical + extra_logical:
            problems.append(f"logical {got['logical_bytes']} != model {expected_logical} + unmodelled {extra_logical}")
        if got["file_count"] != len(model.path_inode) + len(extra):
            problems.append(f"files {got['file_count']} != {len(model.path_inode)} + {len(extra)}, "
                            f"unmodelled e.g. {[str(p.relative_to(mnt)) for p in extra[:3]]}")
        used = int(sh("df", "-k", str(mnt)).stdout.splitlines()[1].split()[2]) * 1024
        if not edited_clone and got["allocated_bytes"] > used:
            problems.append(f"scan {got['allocated_bytes']} exceeds volume used {used} with no edited clones")
        coverage = report["coverage"]
        if clones and coverage["clone_ids_unavailable_directories"]:
            problems.append(f"APFS reported no clone ids in {coverage['clone_ids_unavailable_directories']} directories")
        digests = {
            next(line for line in sh(str(BENCH), "digest", str(mnt)).stdout.splitlines() if line.startswith("digest "))
            for _ in range(5)
        }
        if len(digests) != 1:
            problems.append(f"{len(digests)} different digests over 5 scans")
        print(f"{fs:8s} seed {seed}: {len(model.path_inode):4d} paths, {len(streams):4d} streams, "
              f"scan {got['allocated_bytes'] / 1e6:9.2f} MB, volume used {used / 1e6:9.2f} MB, "
              f"shared {coverage['shared_allocated_bytes'] / 1e6:9.2f} MB, "
              f"no-clone-id dirs {coverage['clone_ids_unavailable_directories']}, "
              f"edited clones {'yes' if edited_clone else 'no'}: {'OK' if not problems else 'FAIL'}")
        for p in problems:
            print("   ", p)
        return not problems
    finally:
        subprocess.run(["hdiutil", "detach", "-force", str(mnt)], capture_output=True)
        image.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seeds", type=int, nargs="+", default=[1, 2, 3])
    parser.add_argument("--ops", type=int, default=300)
    parser.add_argument("--fs", nargs="+", default=list(FILESYSTEMS), choices=list(FILESYSTEMS))
    parser.add_argument("--no-edits", action="store_true", help="never modify files: scan totals must stay within volume used")
    args = parser.parse_args()
    for binary in (CLI, BENCH):
        if not binary.exists():
            raise SystemExit(f"missing {binary}; see the usage above")
    work = Path(tempfile.mkdtemp(prefix="bz-stress-"))
    try:
        results = [check(fs, seed, args.ops, work, not args.no_edits) for fs in args.fs for seed in args.seeds]
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"{sum(results)}/{len(results)} passed")
    raise SystemExit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
