//! C ABI for the Swift UI. A scan runs on background threads; the UI polls
//! progress counters, then receives the finished tree as flat arrays
//! (zero-copy: Swift reads the buffers in place until bz_free).

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{cache, cleanup, scan, Progress, Tree};

pub struct BzScan {
    progress: Arc<Progress>,
    done: Arc<AtomicBool>,
    result: Arc<std::sync::Mutex<Option<Flat>>>,
    // Kept alive for the lifetime of the handle; Swift holds raw pointers in.
    flat: Option<Box<Flat>>,
}

/// The scanned tree (already in the flat layout) plus Clean Up's candidates.
struct Flat {
    tree: Tree,
    cleanup_nodes: Vec<u32>,
    cleanup_descriptions: Vec<CString>,
    root: PathBuf,
    /// When the scan started, so a saved copy can say how old it is.
    scanned_at: SystemTime,
    /// Loaded from a saved scan: never read the disk for it (see bz_reclaimable).
    saved: bool,
}

fn with_cleanup(tree: Tree, root: PathBuf, scanned_at: SystemTime) -> Flat {
    let candidates = cleanup::find(&tree, cleanup::MIN_BYTES);
    Flat {
        cleanup_nodes: candidates.iter().map(|c| c.node).collect(),
        cleanup_descriptions: candidates
            .iter()
            .map(|c| CString::new(c.kind.description()).expect("static cleanup label has no NUL"))
            .collect(),
        tree,
        root,
        scanned_at,
        saved: false,
    }
}

fn path_arg(path: *const c_char) -> PathBuf {
    let path = unsafe { CStr::from_ptr(path) };
    PathBuf::from(String::from_utf8_lossy(path.to_bytes()).into_owned())
}

/// Start a scan on background threads. Returns a handle immediately.
#[no_mangle]
pub extern "C" fn bz_scan_start(path: *const c_char) -> *mut BzScan {
    let path = path_arg(path);

    let progress = Arc::new(Progress::default());
    let done = Arc::new(AtomicBool::new(false));
    let result = Arc::new(std::sync::Mutex::new(None));

    {
        let progress = progress.clone();
        let done = done.clone();
        let result = result.clone();
        std::thread::spawn(move || {
            unsafe { crate::set_thread_qos_user_interactive() };
            let started = SystemTime::now();
            let t0 = std::time::Instant::now();
            let tree = scan(&path, &progress);
            let t1 = std::time::Instant::now();
            let flat = with_cleanup(tree, path, started);
            if std::env::var_os("BZ_TIMING").is_some() {
                eprintln!(
                    "[bz] scan {:.3}s  cleanup {:.1}ms",
                    (t1 - t0).as_secs_f64(),
                    t1.elapsed().as_secs_f64() * 1e3
                );
            }
            *result.lock().unwrap() = Some(flat);
            done.store(true, Ordering::Release);
        });
    }

    Box::into_raw(Box::new(BzScan {
        progress,
        done,
        result,
        flat: None,
    }))
}

#[no_mangle]
pub extern "C" fn bz_progress(
    h: *mut BzScan,
    files: *mut u64,
    dirs: *mut u64,
    bytes: *mut u64,
    done: *mut c_int,
) {
    let h = unsafe { &mut *h };
    unsafe {
        *files = h.progress.files.load(Ordering::Relaxed);
        *dirs = h.progress.dirs.load(Ordering::Relaxed);
        *bytes = h.progress.bytes.load(Ordering::Relaxed);
        *done = h.done.load(Ordering::Acquire) as c_int;
    }
}

/// Load the saved scan of `root` from `cache_path`, on the calling thread.
/// Returns a finished handle (read it as after a scan), or NULL when there is
/// no usable cache: missing, unreadable, damaged, from another format
/// version, or for another folder or volume.
#[no_mangle]
pub extern "C" fn bz_cache_load(cache_path: *const c_char, root: *const c_char) -> *mut BzScan {
    let (cache_path, root) = (path_arg(cache_path), path_arg(root));
    let t0 = std::time::Instant::now();
    let (tree, scanned_at) = match cache::load(&cache_path, &root) {
        Ok(loaded) => loaded,
        Err(e) => {
            if e.kind() != std::io::ErrorKind::NotFound {
                eprintln!("[bz] ignoring saved scan {}: {e}", cache_path.display());
            }
            return std::ptr::null_mut();
        }
    };
    let t1 = std::time::Instant::now();
    let flat = Flat { saved: true, ..with_cleanup(tree, root, scanned_at) };
    if std::env::var_os("BZ_TIMING").is_some() {
        eprintln!(
            "[bz] cache load {:.3}s  cleanup {:.1}ms",
            (t1 - t0).as_secs_f64(),
            t1.elapsed().as_secs_f64() * 1e3
        );
    }
    Box::into_raw(Box::new(BzScan {
        progress: Arc::new(Progress::default()),
        done: Arc::new(AtomicBool::new(true)),
        result: Arc::new(std::sync::Mutex::new(None)),
        flat: Some(Box::new(flat)),
    }))
}

/// Save the handle's tree to `cache_path` (see `cache::save`). Slow for big
/// trees: call it off the main thread. Returns 0, or -1 after logging why.
///
/// # Safety
/// `h` must be a live handle whose tree was taken, not freed concurrently.
#[no_mangle]
pub unsafe extern "C" fn bz_cache_save(h: *mut BzScan, cache_path: *const c_char) -> c_int {
    let h = unsafe { &*h };
    let cache_path = path_arg(cache_path);
    let Some(f) = h.flat.as_ref() else { return -1 };
    let t0 = std::time::Instant::now();
    match cache::save(&f.tree, &f.root, f.scanned_at, &cache_path) {
        Ok(sizes) => {
            if std::env::var_os("BZ_TIMING").is_some() {
                eprintln!(
                    "[bz] cache save {:.3}s  {} bytes",
                    t0.elapsed().as_secs_f64(),
                    sizes.file
                );
            }
            0
        }
        Err(e) => {
            eprintln!("[bz] couldn't save scan to {}: {e}", cache_path.display());
            -1
        }
    }
}

/// When the handle's scan started, in seconds since 1970.
#[no_mangle]
pub extern "C" fn bz_scanned_at(h: *mut BzScan) -> f64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0.0, |f| {
        f.scanned_at.duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
    })
}

/// After done: materialize the flat tree in the handle. Returns node count.
#[no_mangle]
pub extern "C" fn bz_take_tree(h: *mut BzScan) -> u64 {
    let h = unsafe { &mut *h };
    if h.flat.is_none() {
        if let Some(f) = h.result.lock().unwrap().take() {
            h.flat = Some(Box::new(f));
        }
    }
    h.flat.as_ref().map_or(0, |f| f.tree.len() as u64)
}

macro_rules! getter {
    ($name:ident, $field:ident, $ty:ty) => {
        #[no_mangle]
        pub extern "C" fn $name(h: *mut BzScan) -> *const $ty {
            let h = unsafe { &*h };
            h.flat
                .as_ref()
                .map_or(std::ptr::null(), |f| f.tree.$field.as_ptr())
        }
    };
}

getter!(bz_parents, parents, u32);
getter!(bz_alloc, alloc, u64);
getter!(bz_unique, unique, u64);
getter!(bz_logical, logical, u64);
getter!(bz_nfiles, n_files, u32);
getter!(bz_flags, flags, u8);
getter!(bz_child_off, child_off, u32);
getter!(bz_children, children, u32);
getter!(bz_name_off, name_off, u32);
getter!(bz_name_blob, name_blob, u8);

/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_count(h: *mut BzScan) -> u64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0, |f| f.cleanup_nodes.len() as u64)
}

/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
/// Read at most `bz_cleanup_count(h)` elements, before `bz_free(h)`.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_nodes(h: *mut BzScan) -> *const u32 {
    let h = unsafe { &*h };
    h.flat
        .as_ref()
        .map_or(std::ptr::null(), |f| f.cleanup_nodes.as_ptr())
}

/// Write what deleting each of `count` nodes would free (see
/// `Tree::reclaimable`) to `out`. The nodes must not contain one another.
/// This asks the file system about partly cloned files, so prefer calling
/// it off the main thread; it only reads the tree. A saved scan
/// (bz_cache_load) asks nothing and counts partly cloned files as not freed.
///
/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
/// `nodes` and `out` must each have room for `count` elements, and every
/// Out-of-range nodes leave `out` untouched.
#[no_mangle]
pub unsafe extern "C" fn bz_reclaimable(h: *mut BzScan, nodes: *const u32, count: u64, out: *mut u64) {
    let h = unsafe { &*h };
    if count == 0 || nodes.is_null() || out.is_null() {
        return;
    }
    if let Some(f) = h.flat.as_ref() {
        let nodes = unsafe { std::slice::from_raw_parts(nodes, count as usize) };
        if nodes.iter().any(|&n| n as usize >= f.tree.len()) {
            return;
        }
        // A saved scan is shown while the fresh scan walks the disk, so it
        // must not add disk reads of its own; its partly cloned files count
        // as not freed until the fresh scan replaces it.
        let freed = if f.saved { f.tree.reclaimable_with(nodes, |_| None) } else { f.tree.reclaimable(nodes) };
        unsafe { std::ptr::copy_nonoverlapping(freed.as_ptr(), out, freed.len()) };
    }
}

/// Label at a candidate-list index (not a tree node index), valid until bz_free.
///
/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_description(h: *mut BzScan, index: u64) -> *const c_char {
    let h = unsafe { &*h };
    h.flat
        .as_ref()
        .and_then(|f| f.cleanup_descriptions.get(index as usize))
        .map_or(std::ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub extern "C" fn bz_errors(h: *mut BzScan) -> u64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0, |f| f.tree.errors)
}

#[no_mangle]
pub extern "C" fn bz_free(h: *mut BzScan) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::NO_PARENT;

    #[test]
    fn bridge_exposes_the_shared_candidates_and_labels() {
        for bytes in [0, cleanup::MIN_BYTES] {
            let mut tree = Tree::with_root("/root");
            tree.push("node_modules", 0, bytes, bytes, true);
            (tree.alloc[0], tree.unique[0], tree.logical[0]) = (bytes, bytes, bytes);
            tree.link_children();
            assert_eq!(tree.parents, [NO_PARENT, 0]);
            let expected = cleanup::find(&tree, cleanup::MIN_BYTES);
            assert_eq!(expected.len(), (bytes > 0) as usize);
            let mut handle = BzScan {
                progress: Arc::new(Progress::default()),
                done: Arc::new(AtomicBool::new(true)),
                result: Arc::new(std::sync::Mutex::new(None)),
                flat: Some(Box::new(with_cleanup(tree, "/root".into(), UNIX_EPOCH))),
            };
            let h = &mut handle as *mut BzScan;
            assert_eq!(unsafe { bz_cleanup_count(h) } as usize, expected.len());
            let nodes = unsafe { std::slice::from_raw_parts(bz_cleanup_nodes(h), expected.len()) };
            let mut freed = vec![0u64; expected.len()];
            unsafe { bz_reclaimable(h, nodes.as_ptr(), nodes.len() as u64, freed.as_mut_ptr()) };
            for (i, candidate) in expected.iter().enumerate() {
                assert_eq!(nodes[i], candidate.node);
                assert_eq!(freed[i], unsafe { *bz_unique(h).add(candidate.node as usize) });
                let label = unsafe { CStr::from_ptr(bz_cleanup_description(h, i as u64)) };
                assert_eq!(label.to_str().unwrap(), candidate.kind.description());
            }
            assert!(unsafe { bz_cleanup_description(h, expected.len() as u64) }.is_null());
        }
    }

    #[test]
    fn a_saved_scan_never_asks_the_disk_for_private_sizes() {
        // A clone with its first 64 KiB rewritten: only the fresh scan may
        // read its private size from disk.
        let root = std::env::temp_dir().join(format!("bz-test-saved-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("original"), vec![7u8; 1 << 20]).unwrap();
        let (src, dst) = (CString::new(root.join("original").to_str().unwrap()).unwrap(),
                          CString::new(root.join("changed").to_str().unwrap()).unwrap());
        if unsafe { libc::clonefile(src.as_ptr(), dst.as_ptr(), 0) } != 0 {
            let _ = std::fs::remove_dir_all(&root);
            eprintln!("skipped: temp dir is not on APFS");
            return;
        }
        {
            use std::os::unix::fs::FileExt;
            let f = std::fs::OpenOptions::new().write(true).open(root.join("changed")).unwrap();
            f.write_all_at(&[1u8; 65536], 0).unwrap();
            f.sync_all().unwrap();
        }
        let tree = scan(&root, &Progress::default());
        let file = root.join("saved.bzcache");
        cache::save(&tree, &root, UNIX_EPOCH, &file).unwrap();
        let changed = (0..tree.len()).find(|&i| tree.name(i) == "changed").unwrap() as u32;
        assert!(tree.partial_clones.contains(&changed));
        let fresh = Box::into_raw(Box::new(BzScan {
            progress: Arc::new(Progress::default()),
            done: Arc::new(AtomicBool::new(true)),
            result: Arc::new(std::sync::Mutex::new(None)),
            flat: Some(Box::new(with_cleanup(tree, root.clone(), UNIX_EPOCH))),
        }));
        let (cfile, croot) = (CString::new(file.to_str().unwrap()).unwrap(), CString::new(root.to_str().unwrap()).unwrap());
        let saved = bz_cache_load(cfile.as_ptr(), croot.as_ptr());
        assert!(!saved.is_null());
        let freed = |h| {
            let mut out = [u64::MAX];
            unsafe { bz_reclaimable(h, &changed, 1, out.as_mut_ptr()) };
            out[0]
        };
        let (from_disk, from_saved) = (freed(fresh), freed(saved));
        let _ = std::fs::remove_dir_all(&root);
        bz_free(fresh);
        bz_free(saved);
        assert!(from_disk >= 65536, "the fresh scan reads the rewritten blocks: {from_disk}");
        assert_eq!(from_saved, 0, "the saved scan counts them as unknown");
    }
}
