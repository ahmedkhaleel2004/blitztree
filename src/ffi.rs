//! C ABI for the Swift UI. A scan runs on background threads; the UI polls
//! progress counters, then receives the finished tree as flat arrays
//! (zero-copy: Swift reads the buffers in place until bz_free).
//!
//! Nothing here may unwind into C: a panic inside an `extern "C"` fn aborts
//! the process. Entry points that compute (`guarded`) catch it and return
//! their NULL/zero answer; the rest only null-check and read. Locks tolerate
//! poisoning, and a scan that panicked still finishes, with no tree.

use std::any::Any;
use std::ffi::{c_char, c_int, CStr, CString, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use crate::{cleanup, scan, Coverage, Progress, Tree};

/// How a scan stands (`bz_scan_status`). Anything but `Running` means the
/// scan thread has finished and `bz_progress` reports done.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum ScanStatus {
    Running = 0,
    /// A tree was built (`bz_take_tree` hands it over), whole or with
    /// unreadable parts (see `bz_coverage`).
    Done = 1,
    /// `bz_cancel` cut the walk short. There is no tree: a partial one is
    /// never handed over as if it were the scan.
    Cancelled = 2,
    /// The scan could not start or panicked. There is no tree.
    Failed = 3,
}

pub struct BzScan {
    progress: Arc<Progress>,
    /// A `ScanStatus`, written once by the scan thread after `result` is set.
    status: Arc<AtomicU8>,
    /// The scan thread's outcome: the tree, or why there is none (a panic).
    /// Empty for a cancelled scan.
    result: Arc<Mutex<Option<Result<Flat, String>>>>,
    // Kept alive for the lifetime of the handle; Swift holds raw pointers in.
    flat: Option<Box<Flat>>,
}

impl BzScan {
    fn status(&self) -> ScanStatus {
        match self.status.load(Ordering::Acquire) {
            0 => ScanStatus::Running,
            1 => ScanStatus::Done,
            2 => ScanStatus::Cancelled,
            _ => ScanStatus::Failed,
        }
    }
}

/// The scanned tree (already in the flat layout) plus Clean Up's candidates.
struct Flat {
    tree: Tree,
    /// What the scan could not read; the same account the CLI reports.
    coverage: Coverage,
    cleanup_nodes: Vec<u32>,
    cleanup_descriptions: Vec<CString>,
}

fn with_cleanup(tree: Tree, coverage: Coverage) -> Flat {
    let candidates = cleanup::find(&tree, cleanup::MIN_BYTES);
    Flat {
        coverage,
        cleanup_nodes: candidates.iter().map(|c| c.node).collect(),
        cleanup_descriptions: candidates
            .iter()
            .map(|c| CString::new(c.kind.description()).expect("static cleanup label has no NUL"))
            .collect(),
        tree,
    }
}

/// A lock that a panicked holder left poisoned is still taken: every value
/// behind one here is replaced or read whole, never left half-built.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn panic_message(payload: &(dyn Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown panic".into())
}

/// Run an entry point's work so that a panic returns `fallback` instead of
/// unwinding into C.
fn guarded<T>(fallback: T, work: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(work)).unwrap_or_else(|payload| {
        eprintln!("[bz] internal error: {}", panic_message(&*payload));
        fallback
    })
}

/// The path a scan reads: the caller's bytes exactly (not necessarily UTF-8).
/// None for an empty path.
fn scan_path(bytes: &[u8]) -> Option<PathBuf> {
    (!bytes.is_empty()).then(|| PathBuf::from(OsStr::from_bytes(bytes)))
}

/// What the scan thread runs: the walk, then Clean Up's candidates. None when
/// a stop cut the walk short: that tree is dropped here, and the candidates
/// of a partial tree are not looked for.
fn run_scan(path: &Path, progress: &Progress) -> Option<Flat> {
    let t0 = std::time::Instant::now();
    let tree = scan(path, progress);
    if progress.stopped_early() {
        return None;
    }
    let t1 = std::time::Instant::now();
    let coverage = Coverage::of(progress, &tree);
    let flat = with_cleanup(tree, coverage);
    if std::env::var_os("BZ_TIMING").is_some() {
        eprintln!(
            "[bz] scan {:.3}s  cleanup {:.1}ms",
            (t1 - t0).as_secs_f64(),
            t1.elapsed().as_secs_f64() * 1e3
        );
    }
    Some(flat)
}

/// Start a scan on background threads. Returns a handle immediately; the
/// scan always ends with a status other than running, and with no tree if it
/// panicked or was cancelled. NULL for a NULL or empty path, or when the
/// thread cannot be started.
///
/// # Safety
/// `path` must be NULL or a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn bz_scan_start(path: *const c_char) -> *mut BzScan {
    guarded(std::ptr::null_mut(), || {
        if path.is_null() {
            return std::ptr::null_mut();
        }
        let Some(path) = scan_path(unsafe { CStr::from_ptr(path) }.to_bytes()) else {
            return std::ptr::null_mut();
        };
        start_scan(path, Arc::new(Progress::default()))
    })
}

/// `bz_scan_start` with the scan's counters supplied, so a test can hand in
/// ones that were already cancelled.
fn start_scan(path: PathBuf, progress: Arc<Progress>) -> *mut BzScan {
    let status = Arc::new(AtomicU8::new(ScanStatus::Running as u8));
    let result = Arc::new(Mutex::new(None));

    let spawned = {
        let progress = progress.clone();
        let status = status.clone();
        let result = result.clone();
        std::thread::Builder::new().spawn(move || {
            unsafe { crate::set_thread_qos_user_interactive() };
            let (outcome, ended) = match catch_unwind(AssertUnwindSafe(|| run_scan(&path, &progress))) {
                Ok(Some(flat)) => (Some(Ok(flat)), ScanStatus::Done),
                Ok(None) => (None, ScanStatus::Cancelled),
                Err(payload) => (Some(Err(panic_message(&*payload))), ScanStatus::Failed),
            };
            *lock(&result) = outcome;
            status.store(ended as u8, Ordering::Release);
        })
    };
    if spawned.is_err() {
        return std::ptr::null_mut();
    }

    Box::into_raw(Box::new(BzScan {
        progress,
        status,
        result,
        flat: None,
    }))
}

/// Ask a running scan to stop. The scan reads no further directory and ends
/// with status `BZ_SCAN_CANCELLED` and no tree, promptly (within the
/// directories being read at that moment). A no-op for a NULL handle, a scan
/// already over (it keeps its result) and a repeated call.
///
/// # Safety
/// `h` must be NULL or a live scan handle, not being freed concurrently.
#[no_mangle]
pub unsafe extern "C" fn bz_cancel(h: *mut BzScan) {
    if let Some(h) = unsafe { h.as_ref() } {
        h.progress.cancel();
    }
}

/// `BZ_SCAN_*` for the handle. A NULL handle is `BZ_SCAN_FAILED`.
///
/// # Safety
/// `h` must be NULL or a live scan handle, not being freed concurrently.
#[no_mangle]
pub unsafe extern "C" fn bz_scan_status(h: *mut BzScan) -> c_int {
    unsafe { h.as_ref() }.map_or(ScanStatus::Failed, BzScan::status) as c_int
}

/// A NULL handle reports done with zero counters, so a poller stops. A NULL
/// output pointer is skipped.
///
/// # Safety
/// `h` must be NULL or a live scan handle; output pointers must be NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn bz_progress(
    h: *mut BzScan,
    files: *mut u64,
    dirs: *mut u64,
    bytes: *mut u64,
    done: *mut c_int,
) {
    let h = unsafe { h.as_ref() };
    let count = |pick: fn(&Progress) -> &AtomicU64| {
        h.map_or(0, |h| pick(&h.progress).load(Ordering::Relaxed))
    };
    unsafe {
        if let Some(files) = files.as_mut() {
            *files = count(|p| &p.files);
        }
        if let Some(dirs) = dirs.as_mut() {
            *dirs = count(|p| &p.dirs);
        }
        if let Some(bytes) = bytes.as_mut() {
            *bytes = count(|p| &p.bytes);
        }
        if let Some(done) = done.as_mut() {
            *done = h.is_none_or(|h| h.status() != ScanStatus::Running) as c_int;
        }
    }
}

/// After done: materialize the flat tree in the handle. Returns node count;
/// 0 for a NULL handle, a scan not yet done, or a cancelled/failed scan.
///
/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent calls.
#[no_mangle]
pub unsafe extern "C" fn bz_take_tree(h: *mut BzScan) -> u64 {
    guarded(0, || {
        let Some(h) = (unsafe { h.as_mut() }) else {
            return 0;
        };
        if h.flat.is_none() {
            match lock(&h.result).take() {
                Some(Ok(f)) => h.flat = Some(Box::new(f)),
                Some(Err(why)) => eprintln!("[bz] scan failed: {why}"),
                None => {}
            }
        }
        h.flat.as_ref().map_or(0, |f| f.tree.len() as u64)
    })
}

/// The taken tree of a handle; None for a NULL handle or before `bz_take_tree`.
///
/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent mutation or free.
unsafe fn flat_of<'a>(h: *mut BzScan) -> Option<&'a Flat> {
    unsafe { h.as_ref() }?.flat.as_deref()
}

macro_rules! getter {
    ($name:ident, $field:ident, $ty:ty) => {
        /// # Safety
        /// `h` must be NULL or a live scan handle, with no concurrent mutation or free.
        #[no_mangle]
        pub unsafe extern "C" fn $name(h: *mut BzScan) -> *const $ty {
            unsafe { flat_of(h) }.map_or(std::ptr::null(), |f| f.tree.$field.as_ptr())
        }
    };
}

getter!(bz_parents, parents, u32);
getter!(bz_alloc, alloc, u64);
getter!(bz_logical, logical, u64);
getter!(bz_nfiles, n_files, u32);
getter!(bz_flags, flags, u8);

/// One bool per node: everything in its subtree was read. NULL before
/// `bz_take_tree` and for a NULL handle.
///
/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_complete(h: *mut BzScan) -> *const bool {
    unsafe { flat_of(h) }.map_or(std::ptr::null(), |f| f.tree.complete.as_ptr())
}

getter!(bz_child_off, child_off, u32);
getter!(bz_children, children, u32);
getter!(bz_name_off, name_off, u32);
getter!(bz_name_blob, name_blob, u8);

/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_count(h: *mut BzScan) -> u64 {
    unsafe { flat_of(h) }.map_or(0, |f| f.cleanup_nodes.len() as u64)
}

/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent mutation or free.
/// Read at most `bz_cleanup_count(h)` elements, before `bz_free(h)`.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_nodes(h: *mut BzScan) -> *const u32 {
    unsafe { flat_of(h) }.map_or(std::ptr::null(), |f| f.cleanup_nodes.as_ptr())
}

/// Label at a candidate-list index (not a tree node index), valid until bz_free.
///
/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_description(h: *mut BzScan, index: u64) -> *const c_char {
    unsafe { flat_of(h) }
        .and_then(|f| f.cleanup_descriptions.get(usize::try_from(index).ok()?))
        .map_or(std::ptr::null(), |s| s.as_ptr())
}

/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_errors(h: *mut BzScan) -> u64 {
    unsafe { flat_of(h) }.map_or(0, |f| f.tree.errors)
}

/// Write what the scan could not read (the account the CLI prints as
/// `coverage`) to `out`. False, leaving `out` untouched, for a NULL handle
/// or `out` and for a handle without a tree.
///
/// # Safety
/// `h` must be NULL or a live scan handle, with no concurrent mutation or
/// free, and `out` NULL or valid for writing one `BzCoverage`.
#[no_mangle]
pub unsafe extern "C" fn bz_coverage(h: *mut BzScan, out: *mut Coverage) -> bool {
    match (unsafe { flat_of(h) }, unsafe { out.as_mut() }) {
        (Some(flat), Some(out)) => {
            *out = flat.coverage;
            true
        }
        _ => false,
    }
}

/// Release a handle and its buffers. If the scan is still running, ask it to
/// stop first so the background walk winds down promptly and discards its result.
///
/// # Safety
/// `h` must be NULL or a live scan handle, not used concurrently or freed again.
#[no_mangle]
pub unsafe extern "C" fn bz_free(h: *mut BzScan) {
    if !h.is_null() {
        let h = unsafe { Box::from_raw(h) };
        h.progress.cancel();
        drop(h);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::PANIC_MARKER;
    use crate::NO_PARENT;
    use std::sync::atomic::AtomicBool;
    use std::time::{Duration, Instant};

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("d")).unwrap();
        std::fs::write(root.join("d/f"), b"x").unwrap();
        root
    }

    fn c_path(p: &Path) -> CString {
        CString::new(p.as_os_str().as_bytes()).unwrap()
    }

    fn wait_done(h: *mut BzScan) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let (mut f, mut d, mut b, mut done) = (0, 0, 0, 0);
            unsafe { bz_progress(h, &mut f, &mut d, &mut b, &mut done) };
            if done != 0 {
                return;
            }
            assert!(Instant::now() < deadline, "the scan never reported done");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn status(h: *mut BzScan) -> c_int {
        unsafe { bz_scan_status(h) }
    }

    const DONE: c_int = ScanStatus::Done as c_int;
    const CANCELLED: c_int = ScanStatus::Cancelled as c_int;
    const FAILED: c_int = ScanStatus::Failed as c_int;

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
                status: Arc::new(AtomicU8::new(ScanStatus::Done as u8)),
                result: Arc::new(Mutex::new(None)),
                flat: Some(Box::new(with_cleanup(tree, Coverage::default()))),
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
    fn a_panicking_scan_finishes_with_no_tree_and_the_next_scan_is_allowed() {
        let root = temp_root(&format!("{PANIC_MARKER}-ffi"));
        let h = unsafe { bz_scan_start(c_path(&root).as_ptr()) };
        assert!(!h.is_null());
        wait_done(h);
        assert_eq!(status(h), FAILED);
        assert_eq!(unsafe { bz_take_tree(h) }, 0, "no tree from a scan that panicked");
        assert_eq!(unsafe { bz_take_tree(h) }, 0, "and again");
        assert!(unsafe { bz_parents(h).is_null() && bz_name_blob(h).is_null() });
        assert_eq!(unsafe { bz_errors(h) }, 0);
        unsafe { bz_free(h) };

        let ok = temp_root("bz-test-ffi-after-panic");
        let h = unsafe { bz_scan_start(c_path(&ok).as_ptr()) };
        wait_done(h);
        assert_eq!(status(h), DONE);
        assert_eq!(unsafe { bz_take_tree(h) }, 3);
        unsafe { bz_free(h) };
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&ok);
    }

    #[test]
    fn a_poisoned_result_lock_does_not_abort_the_process() {
        let mut tree = Tree::with_root("/root");
        tree.push("a", 0, 1, 1, false);
        crate::finish(&mut tree);
        let result = Arc::new(Mutex::new(Some(Ok(with_cleanup(tree, Coverage::default())))));
        let holder = result.clone();
        let _ = std::thread::spawn(move || {
            let _held = holder.lock().unwrap();
            panic!("poison the lock");
        })
        .join();
        assert!(result.is_poisoned());
        let handle = Box::into_raw(Box::new(BzScan {
            progress: Arc::new(Progress::default()),
            status: Arc::new(AtomicU8::new(ScanStatus::Done as u8)),
            result,
            flat: None,
        }));
        assert_eq!(unsafe { bz_take_tree(handle) }, 2, "the lock is taken despite the poison");
        unsafe { bz_free(handle) };
    }

    #[test]
    fn work_that_panics_returns_the_fallback_instead_of_unwinding() {
        assert_eq!(guarded(7, || -> i32 { panic!("inside an entry point") }), 7);
        assert_eq!(guarded(7, || 8), 8);
    }

    #[test]
    fn every_entry_point_tolerates_a_null_handle_and_null_outputs() {
        let null: *mut BzScan = std::ptr::null_mut();
        let (mut files, mut dirs, mut bytes, mut done) = (9, 9, 9, 0);
        unsafe {
            bz_progress(null, &mut files, &mut dirs, &mut bytes, &mut done);
            assert_eq!((files, dirs, bytes, done), (0, 0, 0, 1), "a poller on no handle stops");
            bz_progress(null, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut());
            let live = Box::into_raw(Box::new(BzScan {
                progress: Arc::new(Progress::default()),
                status: Arc::new(AtomicU8::new(ScanStatus::Running as u8)),
                result: Arc::new(Mutex::new(None)),
                flat: None,
            }));
            bz_progress(live, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut());
            bz_free(live);

            assert_eq!(bz_take_tree(null), 0);
            for getter in [
                bz_parents as unsafe extern "C" fn(*mut BzScan) -> *const u32,
                bz_nfiles,
                bz_child_off,
                bz_children,
                bz_name_off,
            ] {
                assert!(getter(null).is_null());
            }
            assert!(bz_alloc(null).is_null() && bz_logical(null).is_null());
            assert!(bz_flags(null).is_null() && bz_name_blob(null).is_null());
            assert!(bz_complete(null).is_null());
            assert_eq!(bz_errors(null), 0);
            assert_eq!(bz_cleanup_count(null), 0);
            assert!(bz_cleanup_nodes(null).is_null());
            assert!(bz_cleanup_description(null, 0).is_null());
            bz_cancel(null);
            assert_eq!(bz_scan_status(null), FAILED);
            let mut out = Coverage { errors: 7, ..Default::default() };
            assert!(!bz_coverage(null, &mut out) && out.errors == 7);
            assert!(!bz_coverage(null, std::ptr::null_mut()));
            bz_free(null);
        }
    }

    #[test]
    fn scan_start_takes_the_path_bytes_exactly_and_refuses_no_path() {
        unsafe {
            assert!(bz_scan_start(std::ptr::null()).is_null());
            assert!(bz_scan_start(c"".as_ptr()).is_null(), "an empty path is not the current directory");
        }

        let raw: &[u8] = b"/tmp/bz-\xff\xfe-not-utf8/\xc3(x";
        assert_eq!(scan_path(raw).unwrap().as_os_str().as_bytes(), raw, "no lossy conversion");
        assert_eq!(scan_path(b"/a").unwrap(), PathBuf::from("/a"));
        assert!(scan_path(b"").is_none());

        let h = unsafe { bz_scan_start(CString::new(raw).unwrap().as_ptr()) };
        assert!(!h.is_null());
        wait_done(h);
        assert_eq!(unsafe { bz_take_tree(h) }, 1);
        assert_eq!(unsafe { bz_errors(h) }, 1);
        unsafe { bz_free(h) };
    }

    #[test]
    fn a_symlink_to_a_folder_is_scanned_through_the_bridge() {
        let base = temp_root("bz-test-ffi-link");
        let link = base.with_file_name(format!("bz-test-ffi-link-to-{}", std::process::id()));
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&base, &link).unwrap();
        let h = unsafe { bz_scan_start(c_path(&link).as_ptr()) };
        wait_done(h);
        assert_eq!(unsafe { bz_take_tree(h) }, 3, "root, d, f");
        assert_eq!(unsafe { bz_errors(h) }, 0);
        unsafe { bz_free(h) };
        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_dir_all(&base);
    }

    fn wide_root(name: &str, fan: usize) -> PathBuf {
        let root = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for a in 0..fan {
            for b in 0..fan {
                let dir = root.join(format!("a{a}/b{b}"));
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::write(dir.join("f"), b"x").unwrap();
                std::fs::write(dir.join("g"), b"y").unwrap();
            }
        }
        root
    }

    #[test]
    fn a_cancelled_scan_finishes_with_a_cancelled_status_and_no_tree() {
        let root = wide_root("bz-test-ffi-cancelled", 6);
        let progress = Arc::new(Progress::default());
        progress.cancel();
        let h = start_scan(root.clone(), progress);
        assert!(!h.is_null());
        wait_done(h);
        assert_eq!(status(h), CANCELLED, "not done, not failed");
        unsafe {
            assert_eq!(bz_take_tree(h), 0);
            assert_eq!(bz_take_tree(h), 0, "and again");
            assert!(bz_parents(h).is_null() && bz_complete(h).is_null() && bz_name_blob(h).is_null());
            assert_eq!(bz_errors(h), 0);
            let mut c = Coverage::default();
            assert!(!bz_coverage(h, &mut c), "no tree, no coverage");
            bz_cancel(h);
            assert_eq!(status(h), CANCELLED);
            bz_free(h);
        }

        let h = unsafe { bz_scan_start(c_path(&root).as_ptr()) };
        wait_done(h);
        assert_eq!(status(h), DONE);
        assert_eq!(unsafe { bz_take_tree(h) }, 1 + 6 + 36 + 72);
        unsafe {
            bz_cancel(h);
            bz_cancel(h);
            assert_eq!(status(h), DONE);
            assert_eq!(bz_take_tree(h), 1 + 6 + 36 + 72);
            bz_free(h);
        }

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_cancel_that_arrives_mid_scan_never_yields_a_partial_tree() {
        let root = wide_root("bz-test-ffi-mid", 20);
        let whole = 1 + 20 + 400 + 800;
        for delay_us in [0u64, 50, 200, 1000, 5000] {
            let h = unsafe { bz_scan_start(c_path(&root).as_ptr()) };
            std::thread::sleep(Duration::from_micros(delay_us));
            unsafe { bz_cancel(h) };
            wait_done(h);
            match status(h) {
                CANCELLED => assert_eq!(unsafe { bz_take_tree(h) }, 0, "delay {delay_us}"),
                DONE => {
                    assert_eq!(unsafe { bz_take_tree(h) }, whole, "delay {delay_us}");
                    let mut c = Coverage::default();
                    assert!(unsafe { bz_coverage(h, &mut c) } && c.complete);
                }
                other => panic!("status {other}"),
            }
            unsafe { bz_free(h) };
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_bridge_exposes_per_node_completeness_and_the_scans_coverage() {
        let mut tree = Tree::with_root("/root");
        let open = tree.push("open", 0, 0, 0, true);
        tree.push("sealed", 0, 0, 0, true);
        tree.push("a", open, 5, 5, false);
        tree.complete[2] = false;
        crate::finish(&mut tree);
        tree.errors = 2;
        let coverage = Coverage {
            errors: 2,
            entry_errors: 1,
            invalid_names: 1,
            skipped_cloud_directories: 3,
            skipped_mount_points: 4,
            complete: false,
        };
        let mut handle = BzScan {
            progress: Arc::new(Progress::default()),
            status: Arc::new(AtomicU8::new(ScanStatus::Done as u8)),
            result: Arc::new(Mutex::new(None)),
            flat: Some(Box::new(with_cleanup(tree, coverage))),
        };
        let h = &mut handle as *mut BzScan;
        let complete = unsafe { std::slice::from_raw_parts(bz_complete(h), 4) };
        assert_eq!(complete, [false, true, false, true], "root, open, sealed, a");
        let flags = unsafe { std::slice::from_raw_parts(bz_flags(h), 4) };
        assert_eq!(flags[2] & crate::SELF_INCOMPLETE, crate::SELF_INCOMPLETE);
        assert_eq!(flags[0] & crate::SELF_INCOMPLETE, 0, "the root is partial only through its child");

        let mut out = Coverage::default();
        assert!(unsafe { bz_coverage(h, &mut out) });
        assert_eq!(out, coverage);
        assert!(!unsafe { bz_coverage(h, std::ptr::null_mut()) });
    }

    #[test]
    fn freeing_a_running_scan_asks_the_walk_to_stop() {
        let root = wide_root("bz-test-ffi-free-cancel", 15);
        let h = unsafe { bz_scan_start(c_path(&root).as_ptr()) };
        assert!(!h.is_null());
        let progress = unsafe { &*h }.progress.clone();
        unsafe { bz_free(h) };
        assert!(progress.is_cancelled());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    #[ignore = "stress: run explicitly in release"]
    fn stress_cancel_at_random_points_with_concurrent_progress() {
        let root = wide_root("bz-test-ffi-cancel-stress", 25);
        let whole = 1 + 25 + 625 + 1250;
        let path = c_path(&root);
        let (mut cancelled, mut finished) = (0u32, 0u32);
        let mut seed = 0x9e37_79b9_7f4a_7c15u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for round in 0..200u32 {
            let h = unsafe { bz_scan_start(path.as_ptr()) };
            assert!(!h.is_null());
            let addr = h as usize;
            let stop = Arc::new(AtomicBool::new(false));
            let pollers: Vec<_> = (0..2)
                .map(|_| {
                    let stop = stop.clone();
                    std::thread::spawn(move || {
                        let h = addr as *mut BzScan;
                        while !stop.load(Ordering::Acquire) {
                            let (mut f, mut d, mut b, mut done) = (0, 0, 0, 0);
                            unsafe { bz_progress(h, &mut f, &mut d, &mut b, &mut done) };
                        }
                    })
                })
                .collect();
            let (first, again) = (next() % 15_000, next() % 3);
            let cancellers: Vec<_> = (0..1 + again)
                .map(|k| {
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_micros(first * (k + 1)));
                        unsafe { bz_cancel(addr as *mut BzScan) };
                    })
                })
                .collect();
            wait_done(h);
            for c in cancellers {
                c.join().unwrap();
            }
            stop.store(true, Ordering::Release);
            for p in pollers {
                p.join().unwrap();
            }
            match status(h) {
                CANCELLED => {
                    assert_eq!(unsafe { bz_take_tree(h) }, 0, "round {round}");
                    assert!(unsafe { bz_parents(h).is_null() });
                    cancelled += 1;
                }
                DONE => {
                    assert_eq!(unsafe { bz_take_tree(h) }, whole, "round {round}");
                    let complete = unsafe { std::slice::from_raw_parts(bz_complete(h), whole as usize) };
                    assert!(complete.iter().all(|&c| c), "round {round}: a finished scan is whole");
                    finished += 1;
                }
                other => panic!("round {round}: status {other}"),
            }
            unsafe { bz_free(h) };
        }
        eprintln!("cancel stress: {cancelled} cancelled, {finished} finished");
        assert!(cancelled > 0);
        let _ = std::fs::remove_dir_all(&root);
    }
}
