//! Benchmark harness: compares scan strategies on a real directory tree.
//!
//! Usage: bench <mode> <path> [threads]
//!   modes: bulk        - parallel getattrlistbulk (our engine)
//!          ffi         - full app scan, flatten, handoff, and free
//!          digest      - ffi, then check the flat arrays' invariants and print
//!                        an order-independent digest of every (path, sizes, kind)
//!   BZ_DUMP=<file> (digest) also writes the sorted rows, for diffing.
//!   BZ_INCOMPLETE=<file> (bulk) writes the sorted paths of incomplete subtrees.
//!          naive       - serial read_dir + per-file lstat (Disk Inventory X style)
//!          naive-par   - parallel read_dir + per-file lstat
//!   BZ_TOP=1 also prints each top-level entry's allocated bytes (for diffing).
//!          cache       - scan, then report saved-scan sizes and save/load times;
//!                        BZ_CACHE_KEEP=<file> keeps the saved file
//!          cache-load  - load BZ_CACHE_FILE, saved from a scan of <path>, once
//!                        and print the peak memory
//!   BZ_JSON=1 emits machine-readable totals and timing.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use blitztree::{scan, Progress};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("bulk");
    let path = PathBuf::from(args.get(2).map(String::as_str).unwrap_or("."));
    if let Some(t) = args.get(3) {
        let threads: usize = t.parse().expect("threads must be a positive integer");
        assert!(threads > 0, "threads must be positive");
        // scan() creates its own QoS-configured pool. Configuring only the
        // global pool silently left bulk scans at the default thread count.
        std::env::set_var("RAYON_NUM_THREADS", threads.to_string());
    }

    let start = Instant::now();
    let (files, dirs, bytes, errors) = match mode {
        "bulk" => {
            let progress = Progress::default();
            let tree = scan(&path, &progress);
            if let Some(out) = std::env::var_os("BZ_INCOMPLETE") {
                let mut paths: Vec<_> = (0..tree.len())
                    .filter(|&i| !tree.complete[i])
                    .map(|i| tree.path(i).display().to_string())
                    .collect();
                paths.sort_unstable();
                std::fs::write(out, paths.join("\n")).unwrap();
            }
            if std::env::var_os("BZ_TOP").is_some() {
                for &c in tree.kids(0) {
                    eprintln!("TOP\t{}\t{}", tree.name(c as usize), tree.alloc[c as usize]);
                }
            }
            (
                tree.n_files[0] as u64,
                progress.dirs.load(Ordering::Relaxed),
                tree.alloc[0],
                tree.errors,
            )
        }
        "ffi" | "digest" => {
            use blitztree::ffi::*;
            let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
            let handle = bz_scan_start(path.as_ptr());
            let (mut files, mut dirs, mut bytes, mut done) = (0, 0, 0, 0);
            loop {
                bz_progress(handle, &mut files, &mut dirs, &mut bytes, &mut done);
                if done != 0 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            let n = bz_take_tree(handle) as usize;
            assert!(n > 0);
            if mode == "digest" {
                use std::slice::from_raw_parts as s;
                let v = unsafe {
                    let name_off = s(bz_name_off(handle), n + 1);
                    View {
                        parents: s(bz_parents(handle), n),
                        alloc: s(bz_alloc(handle), n),
                        unique: s(bz_unique(handle), n),
                        logical: s(bz_logical(handle), n),
                        n_files: s(bz_nfiles(handle), n),
                        flags: s(bz_flags(handle), n),
                        child_off: s(bz_child_off(handle), n + 1),
                        children: s(bz_children(handle), n - 1),
                        name_off,
                        name_blob: s(bz_name_blob(handle), name_off[n] as usize),
                        errors: bz_errors(handle),
                        cleanup: (0..bz_cleanup_count(handle))
                            .map(|i| {
                                let label = std::ffi::CStr::from_ptr(bz_cleanup_description(handle, i));
                                (*bz_cleanup_nodes(handle).add(i as usize), label.to_string_lossy().into_owned())
                            })
                            .collect(),
                    }
                };
                digest(&v);
            }
            let result = unsafe {
                (
                    *bz_nfiles(handle) as u64,
                    dirs,
                    *bz_alloc(handle),
                    bz_errors(handle),
                )
            };
            bz_free(handle);
            result
        }
        "bulk-count" => {
            let progress = Progress::default();
            blitztree::scan_count(&path, &progress);
            (
                progress.files.load(Ordering::Relaxed),
                progress.dirs.load(Ordering::Relaxed),
                progress.bytes.load(Ordering::Relaxed),
                progress.errors.load(Ordering::Relaxed),
            )
        }
        "searchfs" => {
            let progress = Progress::default();
            match blitztree::searchfs::catalog_dump(&path, &progress) {
                Ok(entries) => {
                    let e = entries.len();
                    eprintln!("  ({e} catalog entries)");
                }
                Err(err) => eprintln!("  searchfs failed: {err}"),
            }
            (
                progress.files.load(Ordering::Relaxed),
                progress.dirs.load(Ordering::Relaxed),
                progress.bytes.load(Ordering::Relaxed),
                progress.errors.load(Ordering::Relaxed),
            )
        }
        "naive" => {
            let mut c = Counts::default();
            naive_walk(&path, &mut c);
            (c.files, c.dirs, c.bytes, c.errors)
        }
        "naive-par" => {
            let c = AtomicCounts::default();
            rayon::scope(|s| naive_walk_par(s, &path, &c));
            (
                c.files.load(Ordering::Relaxed),
                c.dirs.load(Ordering::Relaxed),
                c.bytes.load(Ordering::Relaxed),
                c.errors.load(Ordering::Relaxed),
            )
        }
        "cache" => {
            let progress = Progress::default();
            let tree = scan(&path, &progress);
            cache_report(&tree, &path);
            (
                tree.n_files[0] as u64,
                progress.dirs.load(Ordering::Relaxed),
                tree.alloc[0],
                tree.errors,
            )
        }
        "cache-load" => {
            let file = std::env::var("BZ_CACHE_FILE").expect("cache-load: set BZ_CACHE_FILE");
            let before = peak_rss();
            let t = Instant::now();
            let (tree, _) = blitztree::cache::load(Path::new(&file), &path).expect("cache didn't load");
            println!(
                "cache-load: {} nodes in {:.3}s, peak memory {:.0} MB (was {:.0} MB before loading)",
                tree.len(),
                t.elapsed().as_secs_f64(),
                peak_rss() as f64 / 1e6,
                before as f64 / 1e6
            );
            (tree.n_files[0] as u64, 0, tree.alloc[0], tree.errors)
        }
        m => {
            eprintln!("unknown mode {m}");
            std::process::exit(1);
        }
    };
    let dt = start.elapsed();

    let total = files + dirs;
    if std::env::var_os("BZ_JSON").is_some() {
        println!("{{\"mode\":\"{mode}\",\"seconds\":{:.9},\"files\":{files},\"dirs\":{dirs},\"bytes\":{bytes},\"errors\":{errors}}}", dt.as_secs_f64());
        return;
    }
    println!(
        "{mode:>9}  {:>8.3}s  {files:>9} files  {dirs:>8} dirs  {:>8.2} GB  {errors:>6} errs  {:>10.0} entries/s",
        dt.as_secs_f64(),
        bytes as f64 / 1e9,
        total as f64 / dt.as_secs_f64()
    );
}

/// Saved-scan size and speed for one scanned tree: encoded and compressed
/// size per zstd level, then a real save and load at the shipped level.
/// Load is measured to a usable handle (read, decompress, rebuild totals
/// and child lists, Clean Up candidates), best of three.
fn cache_report(tree: &blitztree::Tree, root: &Path) {
    use blitztree::cache;
    use std::time::{Duration, SystemTime};
    let n = tree.len();
    let memory = 4 * n // parents
        + 3 * 8 * n // alloc, unique, logical
        + 4 * n // n_files
        + 2 * n // flags, complete
        + 4 * (n + 1) + 4 * n.saturating_sub(1) // child_off, children
        + 4 * (n + 1) + tree.name_blob.len() // names
        + 4 * tree.clone_members.len() + 12 * tree.clone_groups.len() + 4 * tree.partial_clones.len();
    let names = tree.name_blob.len();
    println!("cache: {n} nodes, {:.1} MB columns in memory ({:.1} MB of names)", memory as f64 / 1e6, names as f64 / 1e6);
    let header = cache::Header {
        root: root.to_string_lossy().into_owned(),
        scanned_at: SystemTime::now(),
        volume: cache::volume_id(root).unwrap_or_default(),
    };
    let levels: Vec<i32> = std::env::var("BZ_LEVELS")
        .map(|s| s.split(',').map(|l| l.parse().expect("BZ_LEVELS: comma-separated integers")).collect())
        .unwrap_or_else(|_| vec![1, 3, 6, 9]);
    for level in levels {
        let t = Instant::now();
        let (_, sizes) = cache::encode(tree, &header, level).unwrap();
        println!(
            "  level {level:>2}: encoded {:.1} MB -> file {:.1} MB in {:.3}s",
            sizes.encoded as f64 / 1e6,
            sizes.file as f64 / 1e6,
            t.elapsed().as_secs_f64()
        );
        if level == cache::LEVEL {
            for (name, encoded, packed) in &sizes.columns {
                println!("    {name:>14}: {:>7.1} MB -> {:>6.1} MB", *encoded as f64 / 1e6, *packed as f64 / 1e6);
            }
        }
    }
    // What storing folder totals instead of rebuilding them would add.
    let mut totals = Vec::new();
    for i in (0..n).filter(|&i| tree.is_dir(i)) {
        for v in [tree.alloc[i], tree.unique[i], tree.logical[i], tree.n_files[i] as u64] {
            let mut v = v;
            while v >= 0x80 {
                totals.push(v as u8 | 0x80);
                v >>= 7;
            }
            totals.push(v as u8);
        }
    }
    let packed = zstd::bulk::compress(&totals, cache::LEVEL).unwrap();
    println!(
        "  stored folder totals would add {:.1} MB encoded, {:.1} MB compressed",
        totals.len() as f64 / 1e6,
        packed.len() as f64 / 1e6
    );

    let dir = std::env::temp_dir().join(format!("bz-cache-bench-{}", std::process::id()));
    let file = dir.join("scan.bzcache");
    let t = Instant::now();
    let sizes = cache::save(tree, root, SystemTime::now(), &file).unwrap();
    println!("  save at level {}: {:.3}s, {:.1} MB", cache::LEVEL, t.elapsed().as_secs_f64(), sizes.file as f64 / 1e6);
    let cache_c = std::ffi::CString::new(file.as_os_str().as_encoded_bytes()).unwrap();
    let root_c = std::ffi::CString::new(root.as_os_str().as_encoded_bytes()).unwrap();
    let mut best = Duration::MAX;
    for _ in 0..3 {
        let t = Instant::now();
        let h = blitztree::ffi::bz_cache_load(cache_c.as_ptr(), root_c.as_ptr());
        assert!(!h.is_null(), "cache didn't load");
        assert_eq!(blitztree::ffi::bz_take_tree(h) as usize, n);
        best = best.min(t.elapsed());
        blitztree::ffi::bz_free(h);
    }
    println!("  load to usable: {:.3}s (best of 3)", best.as_secs_f64());
    match std::env::var_os("BZ_CACHE_KEEP") {
        Some(keep) => {
            std::fs::rename(&file, &keep).unwrap();
            let _ = std::fs::remove_dir_all(&dir);
        }
        None => {
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}

/// The process's peak resident memory so far, in bytes.
fn peak_rss() -> u64 {
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    // macOS reports bytes.
    usage.ru_maxrss as u64
}

#[derive(Default)]
struct Counts {
    files: u64,
    dirs: u64,
    bytes: u64,
    errors: u64,
}

fn naive_walk(dir: &Path, c: &mut Counts) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        c.errors += 1;
        return;
    };
    for entry in rd.flatten() {
        let (Ok(meta), Ok(ft)) = (entry.metadata(), entry.file_type()) else {
            c.errors += 1;
            continue;
        };
        if ft.is_dir() {
            c.dirs += 1;
            naive_walk(&entry.path(), c);
        } else {
            c.files += 1;
            c.bytes += meta.len();
        }
    }
}

#[derive(Default)]
struct AtomicCounts {
    files: AtomicU64,
    dirs: AtomicU64,
    bytes: AtomicU64,
    errors: AtomicU64,
}

fn naive_walk_par<'s>(scope: &rayon::Scope<'s>, dir: &Path, c: &'s AtomicCounts) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        c.errors.fetch_add(1, Ordering::Relaxed);
        return;
    };
    for entry in rd.flatten() {
        let Ok(meta) = entry.path().symlink_metadata() else {
            c.errors.fetch_add(1, Ordering::Relaxed);
            continue;
        };
        if meta.is_dir() {
            c.dirs.fetch_add(1, Ordering::Relaxed);
            let p = entry.path();
            scope.spawn(move |s| naive_walk_par(s, &p, c));
        } else {
            c.files.fetch_add(1, Ordering::Relaxed);
            c.bytes.fetch_add(meta.len(), Ordering::Relaxed);
        }
    }
}

/// The flat arrays exactly as the Swift UI sees them through the C ABI.
struct View<'a> {
    parents: &'a [u32],
    alloc: &'a [u64],
    unique: &'a [u64],
    logical: &'a [u64],
    n_files: &'a [u32],
    flags: &'a [u8],
    child_off: &'a [u32],
    children: &'a [u32],
    name_off: &'a [u32],
    name_blob: &'a [u8],
    errors: u64,
    /// Clean Up candidates in order: (node, label).
    cleanup: Vec<(u32, String)>,
}

const FNV: u64 = 0xcbf2_9ce4_8422_2325;
fn fnv(mut h: u64, bytes: &[u8]) -> u64 {
    for &b in bytes {
        h = (h ^ b as u64).wrapping_mul(0x100_0000_01b3);
    }
    h
}

/// Verify the flat tree's invariants, then hash it independently of node
/// order (which depends on thread scheduling).
fn digest(f: &View) {
    let n = f.parents.len();
    let name = |i: usize| &f.name_blob[f.name_off[i] as usize..f.name_off[i + 1] as usize];
    assert!(f.alloc.len() == n && f.unique.len() == n && f.logical.len() == n && f.n_files.len() == n && f.flags.len() == n);
    assert!(f.child_off.len() == n + 1 && f.name_off.len() == n + 1);
    assert_eq!(f.child_off[0], 0);
    assert_eq!(f.name_off[0], 0);
    assert_eq!(f.child_off[n] as usize, f.children.len());
    assert_eq!(f.children.len(), n - 1);
    assert_eq!(f.name_off[n] as usize, f.name_blob.len());
    assert_eq!(f.parents[0], u32::MAX);
    let mut seen = vec![false; n];
    for i in 0..n {
        let kids = &f.children[f.child_off[i] as usize..f.child_off[i + 1] as usize];
        let is_dir = f.flags[i] & 1 != 0;
        assert!(is_dir || kids.is_empty());
        let (mut a, mut u, mut l, mut nf) = (0u64, 0u64, 0u64, 0u32);
        for (j, &k) in kids.iter().enumerate() {
            let k = k as usize;
            assert_eq!(f.parents[k] as usize, i, "child's parent");
            assert!(!seen[k], "child listed twice");
            seen[k] = true;
            assert!(j == 0 || f.unique[kids[j - 1] as usize] >= f.unique[k], "children sorted by unique desc");
            assert!(f.unique[k] <= f.alloc[k], "unique within alloc");
            a += f.alloc[k];
            u += f.unique[k];
            l += f.logical[k];
            nf += if f.flags[k] & 1 != 0 { f.n_files[k] } else { 1 };
        }
        if is_dir {
            assert_eq!((f.alloc[i], f.unique[i], f.logical[i], f.n_files[i]), (a, u, l, nf), "dir totals");
        }
    }
    // Children always come after their parent, so paths hash in one pass.
    let mut ph = vec![0u64; n];
    for i in 0..n {
        let p = f.parents[i];
        ph[i] = if p == u32::MAX {
            fnv(FNV, name(i))
        } else {
            assert!((p as usize) < i, "parent before child");
            fnv(fnv(ph[p as usize], b"/"), name(i))
        };
    }
    // Child order by name: ties in size keep the directory's listing order.
    let order = |i: usize| {
        let kids = &f.children[f.child_off[i] as usize..f.child_off[i + 1] as usize];
        kids.iter().fold(FNV, |h, &k| fnv(fnv(h, name(k as usize)), &[0xff]))
    };
    let mut rows: Vec<_> = (0..n)
        .map(|i| (ph[i], f.alloc[i], f.logical[i], f.n_files[i], f.flags[i], order(i), f.unique[i]))
        .collect();
    rows.sort_unstable();
    // `shape` leaves out sizes and order.
    let (mut h, mut shape) = (FNV, FNV);
    for r in &rows {
        shape = fnv(shape, &r.0.to_le_bytes());
        shape = fnv(shape, &r.3.to_le_bytes());
        shape = fnv(shape, &[r.4]);
        h = fnv(h, &r.0.to_le_bytes());
        h = fnv(h, &r.1.to_le_bytes());
        h = fnv(h, &r.2.to_le_bytes());
        h = fnv(h, &r.3.to_le_bytes());
        h = fnv(h, &[r.4]);
        h = fnv(h, &r.5.to_le_bytes());
        h = fnv(h, &r.6.to_le_bytes());
    }
    let mut cleanup = FNV;
    for (node, label) in &f.cleanup {
        cleanup = fnv(fnv(cleanup, &ph[*node as usize].to_le_bytes()), label.as_bytes());
    }
    println!(
        "digest {h:016x}  shape {shape:016x}  cleanup {cleanup:016x} ({})  nodes {n}  alloc {}  unique {}  logical {}  files {}  errors {}  (invariants ok)",
        f.cleanup.len(), f.alloc[0], f.unique[0], f.logical[0], f.n_files[0], f.errors
    );
    if let Some(out) = std::env::var_os("BZ_DUMP") {
        let mut paths: Vec<String> = Vec::with_capacity(n);
        let mut lines: Vec<String> = Vec::with_capacity(n);
        for i in 0..n {
            let nm = String::from_utf8_lossy(name(i));
            let p = f.parents[i];
            let path = if p == u32::MAX { nm.into_owned() } else { format!("{}/{}", paths[p as usize], nm) };
            let kids = &f.children[f.child_off[i] as usize..f.child_off[i + 1] as usize];
            let kids: Vec<_> = kids.iter().map(|&k| String::from_utf8_lossy(name(k as usize))).collect();
            let row = (f.alloc[i], f.logical[i], f.n_files[i], f.flags[i]);
            lines.push(format!("{path}\t{}\t{}\t{}\t{}\t{}", row.0, row.1, row.2, row.3, kids.join("\x1f")));
            paths.push(path);
        }
        lines.sort_unstable();
        std::fs::write(out, lines.join("\n")).unwrap();
    }
}
