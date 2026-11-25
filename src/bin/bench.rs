//! Benchmark harness: compares scan strategies on a real directory tree.
//!
//! Usage: bench <mode> <path> [threads]
//!   modes: bulk        - parallel getattrlistbulk (our engine)
//!          ffi         - full app scan, flatten, handoff, and free
//!          digest      - ffi, then check the flat arrays' invariants and print
//!                        an order-independent digest of every (path, sizes, kind)
//!   BZ_DUMP=<file> (digest) also writes the sorted rows, for diffing.
//!   BZ_INCOMPLETE=<file> (bulk) writes the sorted paths of incomplete subtrees.
//!          search      - scan path, then benchmark interactive query matching
//!          search-synth- benchmark matching over synthetic 3.6M-entry disk scan
//!          naive       - serial read_dir + per-file lstat (Disk Inventory X style)
//!          naive-par   - parallel read_dir + per-file lstat
//!   BZ_TOP=1 also prints each top-level entry's allocated bytes (for diffing).
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
        "search" => {
            let progress = Progress::default();
            let tree = scan(&path, &progress);
            let query = std::env::var("BZ_QUERY").unwrap_or_else(|_| "photo".to_string());
            let runs = 5;
            let mut min_dt = std::time::Duration::MAX;
            let mut total_matches = 0;
            let mut result_count = 0;
            for _ in 0..runs {
                let t0 = Instant::now();
                let (total, results) = tree.search(&query, 1000);
                let dt = t0.elapsed();
                if dt < min_dt {
                    min_dt = dt;
                }
                total_matches = total;
                result_count = results.len();
            }
            let entries = tree.len();
            let eps = entries as f64 / min_dt.as_secs_f64();
            if std::env::var_os("BZ_JSON").is_some() {
                println!(
                    "{{\"mode\":\"search\",\"query\":\"{query}\",\"entries\":{entries},\"matches\":{total_matches},\"returned\":{result_count},\"min_seconds\":{:.9},\"entries_per_sec\":{:.0}}}",
                    min_dt.as_secs_f64(),
                    eps
                );
                return;
            }
            println!(
                "search '{}' on {} entries: {:.3} ms (min of {runs}) -> {total_matches} matches (top {result_count} returned)  {:.0} entries/s",
                query,
                entries,
                min_dt.as_secs_f64() * 1000.0,
                eps
            );
            return;
        }
        "search-synth" => {
            let n: usize = std::env::var("BZ_SYNTH_COUNT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(3_600_000);
            let ties = std::env::var_os("BZ_SYNTH_TIES").is_some();
            println!("Building synthetic tree with {n} entries...");
            let mut tree = blitztree::Tree::default();
            tree.parents.reserve(n);
            tree.alloc.reserve(n);
            tree.logical.reserve(n);
            tree.flags.reserve(n);
            tree.complete.reserve(n);
            tree.name_off.reserve(n + 1);
            tree.name_blob.reserve(n * 20);

            tree.parents.push(blitztree::NO_PARENT);
            tree.alloc.push(100_000_000_000);
            tree.logical.push(100_000_000_000);
            tree.flags.push(1);
            tree.complete.push(true);
            tree.name_off.push(0);
            let root_name = b"/System/Volumes/Data";
            tree.name_blob.extend_from_slice(root_name);
            tree.name_off.push(tree.name_blob.len() as u32);

            let extensions = ["png", "jpg", "pdf", "rs", "swift", "txt", "dylib", "json", "log", "münchen", "東京"];
            for i in 1..n {
                let ext = extensions[i % extensions.len()];
                let name = format!("entry_{i:07}_{}.{}", if i % 10 == 0 { "photo" } else { "file" }, ext);
                tree.parents.push(0);
                let bytes = if ties { 4096 } else { (i as u64 * 1024) % 1_000_000_000 };
                tree.alloc.push(bytes);
                tree.logical.push(bytes);
                tree.flags.push(if i % 8 == 0 { 1 } else { 0 });
                tree.complete.push(true);
                tree.name_blob.extend_from_slice(name.as_bytes());
                tree.name_off.push(tree.name_blob.len() as u32);
            }

            println!("Synthetic tree ready. Benchmarking search queries (min of 5 runs each):");
            let test_queries = [
                "photo",
                "*.png",
                "entry_123*",
                "*.東京",
                "*münchen*",
                "no_such_match_xyz_123",
            ];
            for query in test_queries {
                let mut min_dt = std::time::Duration::MAX;
                let mut total_matches = 0;
                let mut result_count = 0;
                for _ in 0..5 {
                    let t0 = Instant::now();
                    let (total, results) = tree.search(query, 1000);
                    let dt = t0.elapsed();
                    if dt < min_dt {
                        min_dt = dt;
                    }
                    total_matches = total;
                    result_count = results.len();
                }
                let eps = n as f64 / min_dt.as_secs_f64();
                println!(
                    "  {query:<25} {:>7.3} ms  {total_matches:>9} matches (top {result_count:<4})  {:>10.0} entries/s",
                    min_dt.as_secs_f64() * 1000.0,
                    eps
                );
            }
            return;
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
    assert!(f.alloc.len() == n && f.logical.len() == n && f.n_files.len() == n && f.flags.len() == n);
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
        let (mut a, mut l, mut nf) = (0u64, 0u64, 0u32);
        for (j, &k) in kids.iter().enumerate() {
            let k = k as usize;
            assert_eq!(f.parents[k] as usize, i, "child's parent");
            assert!(!seen[k], "child listed twice");
            seen[k] = true;
            assert!(j == 0 || f.alloc[kids[j - 1] as usize] >= f.alloc[k], "children sorted by alloc desc");
            a += f.alloc[k];
            l += f.logical[k];
            nf += if f.flags[k] & 1 != 0 { f.n_files[k] } else { 1 };
        }
        if is_dir {
            assert_eq!((f.alloc[i], f.logical[i], f.n_files[i]), (a, l, nf), "dir totals");
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
        .map(|i| (ph[i], f.alloc[i], f.logical[i], f.n_files[i], f.flags[i], order(i)))
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
    }
    let mut cleanup = FNV;
    for (node, label) in &f.cleanup {
        cleanup = fnv(fnv(cleanup, &ph[*node as usize].to_le_bytes()), label.as_bytes());
    }
    println!(
        "digest {h:016x}  shape {shape:016x}  cleanup {cleanup:016x} ({})  nodes {n}  alloc {}  logical {}  files {}  errors {}  (invariants ok)",
        f.cleanup.len(), f.alloc[0], f.logical[0], f.n_files[0], f.errors
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
