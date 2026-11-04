//! C ABI for the Swift UI. A scan runs on background threads; the UI polls
//! progress counters, then receives the finished tree as flat arrays
//! (zero-copy: Swift reads the buffers in place until bz_free).

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::{cleanup, scan, Progress, Tree};

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
/// it off the main thread; it only reads the tree.
///
/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
/// `nodes` and `out` must each have room for `count` elements. If any node
/// is out of range, `out` is left untouched.
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
        let freed = f.tree.reclaimable(nodes);
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
                flat: Some(Box::new(with_cleanup(tree))),
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
}
