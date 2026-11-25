//! C ABI for the Swift UI. A scan runs on background threads; the UI polls
//! progress counters, then receives the finished tree as flat arrays
//! (zero-copy: Swift reads the buffers in place until bz_free).

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::{cleanup, ranking, scan, types::Breakdown, Progress, Tree};

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
}

fn with_cleanup(tree: Tree) -> Flat {
    let candidates = cleanup::find(&tree, cleanup::MIN_BYTES);
    Flat {
        cleanup_nodes: candidates.iter().map(|c| c.node).collect(),
        cleanup_descriptions: candidates
            .iter()
            .map(|c| CString::new(c.kind.description()).expect("static cleanup label has no NUL"))
            .collect(),
        tree,
    }
}

/// Start a scan on background threads. Returns a handle immediately.
#[no_mangle]
pub extern "C" fn bz_scan_start(path: *const c_char) -> *mut BzScan {
    let path = unsafe { CStr::from_ptr(path) };
    let path = PathBuf::from(String::from_utf8_lossy(path.to_bytes()).into_owned());

    let progress = Arc::new(Progress::default());
    let done = Arc::new(AtomicBool::new(false));
    let result = Arc::new(std::sync::Mutex::new(None));

    {
        let progress = progress.clone();
        let done = done.clone();
        let result = result.clone();
        std::thread::spawn(move || {
            unsafe { crate::set_thread_qos_user_interactive() };
            let t0 = std::time::Instant::now();
            let tree = scan(&path, &progress);
            let t1 = std::time::Instant::now();
            let flat = with_cleanup(tree);
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

/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
///
/// Label at a candidate-list index (not a tree node index), valid until bz_free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_description(h: *mut BzScan, index: u64) -> *const c_char {
    let h = unsafe { &*h };
    h.flat
        .as_ref()
        .and_then(|f| f.cleanup_descriptions.get(index as usize))
        .map_or(std::ptr::null(), |s| s.as_ptr())
}

pub struct BzLargest {
    nodes: Vec<u32>,
}

/// The `limit` largest files of at least `min_bytes` allocated, as tree node
/// indices (largest first). Selected from the scan in place; no tree copy.
/// Returns NULL without a finished scan.
///
/// # Safety
/// `h` must be null or a live scan handle with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_largest_files(
    h: *mut BzScan,
    limit: u32,
    min_bytes: u64,
) -> *mut BzLargest {
    if h.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*h };
    let Some(flat) = h.flat.as_ref() else {
        return std::ptr::null_mut();
    };
    let nodes = ranking::largest_files(&flat.tree, min_bytes, limit as usize)
        .into_iter()
        .map(|i| i as u32)
        .collect();
    Box::into_raw(Box::new(BzLargest { nodes }))
}

/// # Safety
/// `l` must be null or a pointer returned by `bz_largest_files` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn bz_largest_count(l: *mut BzLargest) -> u32 {
    if l.is_null() {
        return 0;
    }
    unsafe { &*l }.nodes.len() as u32
}

/// Valid for `bz_largest_count(l)` elements until `bz_largest_free(l)`.
///
/// # Safety
/// `l` must be null or a pointer returned by `bz_largest_files` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn bz_largest_nodes(l: *mut BzLargest) -> *const u32 {
    if l.is_null() {
        return std::ptr::null();
    }
    unsafe { &*l }.nodes.as_ptr()
}

/// # Safety
/// `l` must be null or a pointer returned by `bz_largest_files` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn bz_largest_free(l: *mut BzLargest) {
    if !l.is_null() {
        drop(unsafe { Box::from_raw(l) });
    }
}

/// Bytes and file counts per extension under `root`. Null without a tree or
/// for a node outside it.
///
/// # Safety
/// `h` must be null or a live scan handle with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_types(h: *mut BzScan, root: u32) -> *mut Breakdown {
    if h.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*h };
    match h.flat.as_ref() {
        Some(flat) if (root as usize) < flat.tree.len() => {
            Box::into_raw(Box::new(flat.tree.types(root as usize)))
        }
        _ => std::ptr::null_mut(),
    }
}

/// # Safety
/// `t` must be null or a pointer returned by `bz_types` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn bz_types_count(t: *mut Breakdown) -> u32 {
    if t.is_null() {
        return 0;
    }
    unsafe { &*t }.len() as u32
}

macro_rules! types_getter {
    ($name:ident, $field:ident, $ty:ty) => {
        /// # Safety
        /// `t` must be null or a pointer returned by `bz_types` and not yet freed.
        #[no_mangle]
        pub unsafe extern "C" fn $name(t: *mut Breakdown) -> *const $ty {
            if t.is_null() {
                return std::ptr::null();
            }
            unsafe { &*t }.$field.as_ptr()
        }
    };
}

types_getter!(bz_types_ext_off, ext_off, u32);
types_getter!(bz_types_ext_blob, ext_blob, u8);
types_getter!(bz_types_alloc, alloc, u64);
types_getter!(bz_types_files, files, u64);

/// # Safety
/// `t` must be null or a pointer returned by `bz_types` and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn bz_types_free(t: *mut Breakdown) {
    if !t.is_null() {
        drop(unsafe { Box::from_raw(t) });
    }
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
            (tree.alloc[0], tree.logical[0]) = (bytes, bytes);
            tree.link_children();
            assert_eq!(tree.parents, [NO_PARENT, 0]);
            let expected = cleanup::find(&tree, cleanup::MIN_BYTES);
            assert_eq!(expected.len(), (bytes > 0) as usize);
            let mut handle = BzScan {
                progress: Arc::new(Progress::default()),
                done: Arc::new(AtomicBool::new(true)),
                result: Arc::new(std::sync::Mutex::new(None)),
                flat: Some(Box::new(with_cleanup(tree))),
            };
            let h = &mut handle as *mut BzScan;
            assert_eq!(unsafe { bz_cleanup_count(h) } as usize, expected.len());
            let nodes = unsafe { std::slice::from_raw_parts(bz_cleanup_nodes(h), expected.len()) };
            for (i, candidate) in expected.iter().enumerate() {
                assert_eq!(nodes[i], candidate.node);
                let label = unsafe { CStr::from_ptr(bz_cleanup_description(h, i as u64)) };
                assert_eq!(label.to_str().unwrap(), candidate.kind.description());
            }
            assert!(unsafe { bz_cleanup_description(h, expected.len() as u64) }.is_null());
        }
    }

    #[test]
    fn bridge_lists_largest_files_like_the_library() {
        let mut tree = Tree::with_root("/root");
        tree.push("dir", 0, 1000, 1000, true);
        tree.push("a.bin", 1, 300, 300, false);
        tree.push("b.bin", 0, 700, 700, false);
        tree.push("c.bin", 1, 5, 5, false);
        tree.link_children();
        let expected = ranking::largest_files(&tree, 10, 5);
        let mut handle = BzScan {
            progress: Arc::new(Progress::default()),
            done: Arc::new(AtomicBool::new(true)),
            result: Arc::new(std::sync::Mutex::new(None)),
            flat: Some(Box::new(with_cleanup(tree))),
        };
        let h = &mut handle as *mut BzScan;
        let l = unsafe { bz_largest_files(h, 5, 10) };
        assert!(!l.is_null());
        assert_eq!(unsafe { bz_largest_count(l) } as usize, expected.len());
        let nodes = unsafe { std::slice::from_raw_parts(bz_largest_nodes(l), expected.len()) };
        assert_eq!(nodes, [3, 2]);
        assert_eq!(
            nodes.iter().map(|&n| n as usize).collect::<Vec<_>>(),
            expected
        );
        unsafe { bz_largest_free(l) };
        assert!(unsafe { bz_largest_files(std::ptr::null_mut(), 5, 0) }.is_null());
    }

    #[test]
    fn bridge_returns_the_type_breakdown_of_a_folder() {
        let mut tree = Tree::with_root("/root");
        let pics = tree.push("pics", 0, 0, 0, true);
        tree.push("notes", 0, 3, 3, false);
        tree.push("a.JPG", pics, 900, 900, false);
        tree.push("b.png", pics, 100, 100, false);
        crate::finish(&mut tree);

        let mut handle = BzScan {
            progress: Arc::new(Progress::default()),
            done: Arc::new(AtomicBool::new(true)),
            result: Arc::new(std::sync::Mutex::new(None)),
            flat: Some(Box::new(with_cleanup(tree))),
        };
        let h = &mut handle as *mut BzScan;
        let t = unsafe { bz_types(h, 0) };
        assert!(!t.is_null());
        let n = unsafe { bz_types_count(t) } as usize;
        assert_eq!(n, 3);
        let (off, alloc, files) = unsafe {
            (
                std::slice::from_raw_parts(bz_types_ext_off(t), n + 1),
                std::slice::from_raw_parts(bz_types_alloc(t), n),
                std::slice::from_raw_parts(bz_types_files(t), n),
            )
        };
        let blob = unsafe { std::slice::from_raw_parts(bz_types_ext_blob(t), off[n] as usize) };
        let exts: Vec<&[u8]> = (0..n)
            .map(|i| &blob[off[i] as usize..off[i + 1] as usize])
            .collect();
        assert_eq!(exts, [&b"jpg"[..], b"png", b""]);
        assert_eq!(alloc, [900, 100, 3]);
        assert_eq!(files, [1, 1, 1]);
        unsafe { bz_types_free(t) };

        let t = unsafe { bz_types(h, pics) };
        assert_eq!(unsafe { bz_types_count(t) }, 2);
        unsafe { bz_types_free(t) };
        assert!(unsafe { bz_types(h, 5) }.is_null());
        assert!(unsafe { bz_types(std::ptr::null_mut(), 0) }.is_null());
        assert_eq!(unsafe { bz_types_count(std::ptr::null_mut()) }, 0);
    }
}
