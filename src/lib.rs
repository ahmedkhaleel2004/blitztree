//! Ultra-fast APFS directory tree scanner using getattrlistbulk(2).
//!
//! getattrlistbulk returns a whole batch of directory entries *with* their
//! metadata (name, type, sizes) per syscall, so we never pay the classic
//! readdir-then-stat-per-file cost that makes naive scanners slow on macOS.

pub mod cleanup;
pub mod ffi;
pub mod searchfs;

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_int, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

// ---- FFI: getattrlistbulk ----

#[repr(C)]
struct AttrList {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

extern "C" {
    fn getattrlistbulk(
        dirfd: c_int,
        attr_list: *mut AttrList,
        attr_buf: *mut c_void,
        attr_buf_size: usize,
        options: u64,
    ) -> c_int;
}

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_DEVID: u32 = 0x0000_0002;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_FLAGS: u32 = 0x0004_0000;
const ATTR_CMN_FILEID: u32 = 0x0200_0000;
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_DIR_MOUNTSTATUS: u32 = 0x0000_0004;
const DIR_MNTSTATUS_MNTPOINT: u32 = 0x0000_0001;
const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

const VDIR: u32 = 2;
/// Contents live in the cloud (iCloud Drive, File Provider). Opening such a
/// directory asks the provider to materialize it, i.e. download.
const SF_DATALESS: u32 = 0x4000_0000;

const BUF_SIZE: usize = 256 * 1024;

// ---- Tree model ----

pub const NO_PARENT: u32 = u32::MAX;
/// `Tree::flags` bit: the node itself was not fully read (see `Tree::complete`).
pub const SELF_INCOMPLETE: u8 = 2;

/// The finished tree as flat arrays, the layout the Swift UI reads in place
/// (see app/bz.h). Node 0 is the root; children come after their parent.
#[derive(Default)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
pub struct Tree {
    pub parents: Vec<u32>,
    /// Allocated (on-disk) bytes; subtree totals for directories.
    pub alloc: Vec<u64>,
    /// Logical bytes; subtree totals for directories.
    pub logical: Vec<u64>,
    /// Subtree file count for directories, 0 for files.
    pub n_files: Vec<u32>,
    pub flags: Vec<u8>, // bit0 = is_dir
    /// False when an entry was unreadable or a cloud/mount boundary was skipped
    /// anywhere in this subtree. The observed sizes then describe a partial walk.
    pub complete: Vec<bool>,
    /// Node i's children are children[child_off[i]..child_off[i + 1]],
    /// largest allocated size first (treemap layout order).
    pub child_off: Vec<u32>,
    pub children: Vec<u32>,
    /// Node i's name is name_blob[name_off[i]..name_off[i + 1]], UTF-8.
    pub name_off: Vec<u32>,
    pub name_blob: Vec<u8>,
    pub errors: u64,
}

impl Tree {
    pub fn len(&self) -> usize {
        self.parents.len()
    }
    pub fn is_empty(&self) -> bool {
        self.parents.is_empty()
    }
    pub fn is_dir(&self, i: usize) -> bool {
        self.flags[i] & 1 != 0
    }
    pub fn kids(&self, i: usize) -> &[u32] {
        &self.children[self.child_off[i] as usize..self.child_off[i + 1] as usize]
    }
    fn name_bytes(&self, i: usize) -> &[u8] {
        &self.name_blob[self.name_off[i] as usize..self.name_off[i + 1] as usize]
    }
    /// Names are validated UTF-8 when scanned.
    pub fn name(&self, i: usize) -> &str {
        std::str::from_utf8(self.name_bytes(i)).unwrap_or("")
    }
    pub fn path(&self, mut i: usize) -> PathBuf {
        let mut parts = Vec::new();
        while i != 0 {
            parts.push(self.name(i));
            i = self.parents[i] as usize;
        }
        let mut path = PathBuf::from(self.name(0));
        for part in parts.into_iter().rev() {
            path.push(part);
        }
        path
    }
    /// Path components from the root, compared as `str`s compare (bytewise).
    fn path_parts(&self, mut i: u32) -> Vec<&[u8]> {
        let mut parts = Vec::new();
        while i != NO_PARENT {
            parts.push(self.name_bytes(i as usize));
            i = self.parents[i as usize];
        }
        parts.reverse();
        parts
    }
}

#[derive(Default)]
pub struct Progress {
    pub files: AtomicU64,
    pub dirs: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
    pub entry_errors: AtomicU64,
    pub invalid_names: AtomicU64,
    pub skipped_cloud_dirs: AtomicU64,
    pub skipped_mount_points: AtomicU64,
    /// A stop was asked for (`cancel`). The walk checks it before reading
    /// each directory and between the batches of a large one.
    cancelled: AtomicBool,
    /// The walk really left a directory unread because of `cancelled`. A
    /// stop that arrives after the last directory was read leaves this
    /// false: that tree is whole and is not reported as cut short.
    stopped_early: AtomicBool,
    /// Test seam: cancel once this many directories have been entered (0
    /// is off). Per scan, so parallel tests cannot disturb each other.
    #[cfg(test)]
    cancel_after_dirs: AtomicU64,
}

impl Progress {
    /// Ask the scan to stop. The walk then reads no further directory; every
    /// one it did not read is left incomplete, and `stopped_early` says so.
    /// Safe from any thread, repeatable, and harmless once the walk is over.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    /// Whether a stop cut the walk short, so the tree describes only part of
    /// what was asked for. Final once `scan` has returned.
    pub fn stopped_early(&self) -> bool {
        self.stopped_early.load(Ordering::Acquire)
    }

    /// True (and recorded) when the walk should leave the directory it is
    /// about to read.
    fn stop_here(&self) -> bool {
        #[cfg(test)]
        if self.cancel_after_dirs.load(Ordering::Relaxed) != 0
            && self.cancel_after_dirs.fetch_sub(1, Ordering::Relaxed) == 1
        {
            self.cancel();
        }
        self.stopped()
    }

    /// Whether a stop was asked for, recording that it cut the walk short.
    fn stopped(&self) -> bool {
        let stop = self.is_cancelled();
        if stop {
            self.stopped_early.store(true, Ordering::Release);
        }
        stop
    }
}

/// What a finished scan could and could not read: the one account of
/// coverage, handed to the CLI report and (by value, `#[repr(C)]`) to the app
/// through `bz_coverage`. Built only by `Coverage::of`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Coverage {
    /// Failed reads of every kind: unreadable directories, failed listings,
    /// dropped entries.
    pub errors: u64,
    /// Entries that could not be read or whose record was malformed.
    pub entry_errors: u64,
    /// Entries dropped because their name is not valid UTF-8. They and
    /// anything below them are missing from the tree.
    pub invalid_names: u64,
    /// Cloud-only directories left unread (reading them would download them).
    pub skipped_cloud_directories: u64,
    /// Mount points left unread (a scan measures one volume).
    pub skipped_mount_points: u64,
    /// Every directory was read in full: nothing unreadable or skipped.
    pub complete: bool,
}

impl Coverage {
    /// The counters of a finished scan with its tree's root state.
    pub fn of(progress: &Progress, tree: &Tree) -> Coverage {
        let count = |c: &AtomicU64| c.load(Ordering::Relaxed);
        Coverage {
            errors: tree.errors,
            entry_errors: count(&progress.entry_errors),
            invalid_names: count(&progress.invalid_names),
            skipped_cloud_directories: count(&progress.skipped_cloud_dirs),
            skipped_mount_points: count(&progress.skipped_mount_points),
            complete: tree.complete.first().copied().unwrap_or(false),
        }
    }
}

struct Entry {
    /// End of this entry's name in `Scratch::names` (it starts where the
    /// previous one ends).
    name_end: u32,
    is_dir: bool,
    /// Contents live in the cloud; not descended (that would download them).
    dataless: bool,
    /// Another volume is mounted here (a disk image, Recovery, a simulator
    /// runtime, autofs). Not descended: a scan measures one volume.
    mount_point: bool,
    size: u64,
    alloc: u64,
    /// `(device, file id)` when the file has more than one hard link.
    hardlink: Option<(u32, u64)>,
}

impl Entry {
    fn descend(&self) -> bool {
        self.is_dir && !self.dataless && !self.mount_point
    }
}

/// Per-thread buffers reused for every directory, so reading one allocates nothing.
#[derive(Default)]
struct Scratch {
    buf: Vec<u8>,
    entries: Vec<Entry>,
    names: Vec<u8>,
}

thread_local! {
    static SCRATCH: RefCell<Scratch> = RefCell::default();
}

/// Whether `BZ_LOG_ERRORS` is set: unreadable directories, failed reads and
/// dropped entries are then reported on stderr. Read once.
fn log_errors_enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("BZ_LOG_ERRORS").is_some())
}

fn log_error(message: impl FnOnce() -> String) {
    if log_errors_enabled() {
        eprintln!("[bz] {}", message());
    }
}

/// How many times in a row an interrupted `getattrlistbulk` is asked again
/// before the directory is reported partial.
const MAX_INTERRUPTS: u32 = 8;

/// Run `call` again while it fails with EINTR or EAGAIN, at most
/// `MAX_INTERRUPTS` times in a row. The last result (and its `errno`) is
/// returned untouched.
fn retry_interrupted(mut call: impl FnMut() -> c_int) -> c_int {
    let mut n = call();
    for _ in 0..MAX_INTERRUPTS {
        if n >= 0
            || !matches!(
                std::io::Error::last_os_error().raw_os_error(),
                Some(libc::EINTR | libc::EAGAIN)
            )
        {
            break;
        }
        n = call();
    }
    n
}

/// # Safety
/// `fd` is an open directory and `buf` holds `BUF_SIZE` writable bytes.
unsafe fn bulk_syscall(fd: c_int, attrlist: &mut AttrList, buf: *mut c_void, options: u64) -> c_int {
    #[cfg(test)]
    if tests::take_injected_interrupt() {
        *libc::__error() = libc::EINTR;
        return -1;
    }
    getattrlistbulk(fd, attrlist, buf, BUF_SIZE, options)
}

/// Read all entries of one directory in bulk into `s`. None if it can't be
/// opened, else whether every entry was read.
fn read_dir_bulk(path: &CStr, s: &mut Scratch, progress: &Progress) -> Option<bool> {
    s.entries.clear();
    s.names.clear();
    if s.buf.is_empty() {
        s.buf = vec![0u8; BUF_SIZE];
    }
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        progress.errors.fetch_add(1, Ordering::Relaxed);
        log_error(|| format!("skip {} ({})", path.to_string_lossy(), std::io::Error::last_os_error()));
        return None;
    }

    let mut attrlist = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID,
        volattr: 0,
        dirattr: ATTR_DIR_MOUNTSTATUS,
        fileattr: ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
        forkattr: 0,
    };

    let mut complete = true;
    let mut read_any = false;
    loop {
        // A directory of millions of entries is read in many batches: a stop
        // does not wait for the last one. What was listed so far is kept.
        if read_any && progress.stopped() {
            complete = false;
            break;
        }
        let n = retry_interrupted(|| unsafe {
            bulk_syscall(fd, &mut attrlist, s.buf.as_mut_ptr() as *mut c_void, 0)
        });
        if n <= 0 {
            if n < 0 {
                progress.errors.fetch_add(1, Ordering::Relaxed);
                complete = false;
                log_error(|| format!("read {} ({})", path.to_string_lossy(), std::io::Error::last_os_error()));
            }
            break;
        }
        read_any = true;
        complete &= parse_batch(&s.buf, n as usize, &mut s.entries, &mut s.names, progress, path);
    }
    unsafe { libc::close(fd) };
    Some(complete)
}

/// Parse the `n` records one `getattrlistbulk` call put in `buf`. False if any
/// entry had to be dropped (unreadable, malformed, or a name that is not
/// UTF-8: it and everything below it are then missing from the tree, so its
/// directory is incomplete).
fn parse_batch(
    buf: &[u8],
    n: usize,
    entries: &mut Vec<Entry>,
    names: &mut Vec<u8>,
    progress: &Progress,
    path: &CStr,
) -> bool {
    let mut complete = true;
    let mut off = 0usize;
    for _ in 0..n {
        // A record must hold its own length and fit in the buffer.
        let len = buf.get(off..off + 4).map_or(0, |_| u32_at(buf, off) as usize);
        let Some(record) = buf.get(off..off + len).filter(|_| len >= 4) else {
            progress.entry_errors.fetch_add(1, Ordering::Relaxed);
            progress.errors.fetch_add(1, Ordering::Relaxed);
            log_error(|| format!("malformed record list in {}", path.to_string_lossy()));
            return false;
        };
        if !parse_entry(record, entries, names, progress) {
            complete = false;
            log_error(|| {
                format!(
                    "entry dropped in {} (unreadable, malformed or non-UTF-8 name)",
                    path.to_string_lossy()
                )
            });
        }
        off += len;
    }
    complete
}

fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

fn i64_at(b: &[u8], off: usize) -> i64 {
    i64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

fn u64_at(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

/// Parse one getattrlistbulk entry. Attribute order within an entry is fixed:
/// RETURNED_ATTRS, ERROR, then common attrs by bit (NAME, DEVID, OBJTYPE,
/// FLAGS, FILEID), then dir attrs (MOUNTSTATUS), then file attrs (LINKCOUNT,
/// TOTALSIZE, ALLOCSIZE). Dir attrs come back only for directories and file
/// attrs only for files. False (and counted) if the entry had to be dropped.
fn parse_entry(e: &[u8], out: &mut Vec<Entry>, names: &mut Vec<u8>, progress: &Progress) -> bool {
    let malformed = || {
        progress.entry_errors.fetch_add(1, Ordering::Relaxed);
        progress.errors.fetch_add(1, Ordering::Relaxed);
        false
    };
    let mut off = 4usize; // skip length
    if e.len() < off + 20 {
        return malformed();
    }
    let ret_common = u32_at(e, off);
    let ret_dir = u32_at(e, off + 8);
    let ret_file = u32_at(e, off + 12);
    off += 20; // attribute_set_t: 5 x u32
    let fixed: usize = [
        (ret_common & ATTR_CMN_ERROR, 4),
        (ret_common & ATTR_CMN_NAME, 8),
        (ret_common & ATTR_CMN_DEVID, 4),
        (ret_common & ATTR_CMN_OBJTYPE, 4),
        (ret_common & ATTR_CMN_FLAGS, 4),
        (ret_common & ATTR_CMN_FILEID, 8),
        (ret_dir & ATTR_DIR_MOUNTSTATUS, 4),
        (ret_file & ATTR_FILE_LINKCOUNT, 4),
        (ret_file & ATTR_FILE_TOTALSIZE, 8),
        (ret_file & ATTR_FILE_ALLOCSIZE, 8),
    ]
    .iter()
    .filter(|(bit, _)| *bit != 0)
    .map(|(_, len)| len)
    .sum();
    if e.len() < off + fixed {
        return malformed();
    }

    if ret_common & ATTR_CMN_ERROR != 0 {
        let err = u32_at(e, off);
        off += 4;
        if err != 0 {
            return malformed();
        }
    }

    let invalid_name = || {
        progress.invalid_names.fetch_add(1, Ordering::Relaxed);
        progress.errors.fetch_add(1, Ordering::Relaxed);
        false
    };
    let mut name: &[u8] = &[];
    if ret_common & ATTR_CMN_NAME != 0 {
        let data_off = u32_at(e, off) as i32 as isize;
        let data_len = u32_at(e, off + 4) as usize;
        // data_len includes the trailing NUL
        let range = (off as isize)
            .checked_add(data_off)
            .and_then(|start| usize::try_from(start).ok())
            .and_then(|start| Some(start..start.checked_add(data_len.saturating_sub(1))?));
        let Some(name_bytes) = range.and_then(|r| e.get(r)) else {
            return malformed();
        };
        name = name_bytes;
        if std::str::from_utf8(name).is_err() {
            return invalid_name();
        }
        off += 8;
    }

    let mut dev = 0u32;
    if ret_common & ATTR_CMN_DEVID != 0 {
        dev = u32_at(e, off);
        off += 4;
    }

    let mut is_dir = false;
    if ret_common & ATTR_CMN_OBJTYPE != 0 {
        is_dir = u32_at(e, off) == VDIR;
        off += 4;
    }

    let mut flags = 0u32;
    if ret_common & ATTR_CMN_FLAGS != 0 {
        flags = u32_at(e, off);
        off += 4;
    }

    let mut file_id = 0u64;
    if ret_common & ATTR_CMN_FILEID != 0 {
        file_id = u64_at(e, off);
        off += 8;
    }

    let mut mount_point = false;
    if ret_dir & ATTR_DIR_MOUNTSTATUS != 0 {
        mount_point = u32_at(e, off) & DIR_MNTSTATUS_MNTPOINT != 0;
        off += 4;
    }

    let mut links = 1u32;
    if ret_file & ATTR_FILE_LINKCOUNT != 0 {
        links = u32_at(e, off);
        off += 4;
    }

    let mut size = 0u64;
    let mut alloc = 0u64;
    if ret_file & ATTR_FILE_TOTALSIZE != 0 {
        size = i64_at(e, off).max(0) as u64;
        off += 8;
    }
    if ret_file & ATTR_FILE_ALLOCSIZE != 0 {
        alloc = i64_at(e, off).max(0) as u64;
    }

    if name.is_empty() {
        return invalid_name();
    }
    let before = names.len();
    names.extend_from_slice(name);
    let Ok(name_end) = u32::try_from(names.len()) else {
        names.truncate(before);
        return malformed();
    };
    out.push(Entry {
        name_end,
        is_dir,
        dataless: flags & SF_DATALESS != 0,
        mount_point,
        size,
        alloc,
        hardlink: (!is_dir && links > 1).then_some((dev, file_id)),
    });
    true
}

// ---- Parallel walk ----

/// The tree as the walk grows it: every field of `Tree` except n_files,
/// child_off and children, which `finish` derives. A directory's entries are
/// appended under one short lock, so its children get one contiguous run of
/// indices, and no node owns a heap allocation.
struct Arena {
    tree: Tree,
    /// Attribute an inode's bytes to its lexicographically first scanned path,
    /// independently of worker scheduling. This is accounting, not an estimate
    /// of how many bytes deleting any one of its links would reclaim.
    hardlinks: HashMap<(u32, u64), u32>,
}

impl Arena {
    /// Called under the arena lock after appending a file, before totals are
    /// aggregated. Returns newly accounted bytes for the progress counter.
    fn account_file(&mut self, i: u32, hardlink: Option<(u32, u64)>) -> u64 {
        let t = &mut self.tree;
        let Some(key) = hardlink else {
            return t.alloc[i as usize];
        };
        let Some(&previous) = self.hardlinks.get(&key) else {
            self.hardlinks.insert(key, i);
            return t.alloc[i as usize];
        };
        let (i, previous) = (i as usize, previous as usize);
        let loser = if t.path_parts(i as u32) < t.path_parts(previous as u32) {
            t.logical[i] = t.logical[previous];
            t.alloc[i] = t.alloc[previous];
            self.hardlinks.insert(key, i as u32);
            previous
        } else {
            i
        };
        t.logical[loser] = 0;
        t.alloc[loser] = 0;
        0
    }
}

/// How much the tree's 32-bit ABI columns can hold: node numbers, and the
/// end offsets into the name blob. A walk that would pass either leaves that
/// directory unlisted and marks it incomplete instead of letting a count wrap.
/// Within these bounds the derived columns cannot wrap either: `n_files` and
/// `child_off` never exceed the node count.
#[derive(Clone, Copy)]
struct Limits {
    nodes: u64,
    name_bytes: u64,
}

impl Limits {
    const ABI: Limits = Limits {
        nodes: u32::MAX as u64,
        name_bytes: u32::MAX as u64,
    };
}

struct Shared<'a> {
    arena: Mutex<Arena>,
    progress: &'a Progress,
    limits: Limits,
}

impl Shared<'_> {
    fn mark_incomplete(&self, i: u32) {
        self.arena.lock().unwrap().tree.complete[i as usize] = false;
    }
}

fn child_path(dir: &CStr, name: &[u8]) -> Option<CString> {
    let dir = dir.to_bytes();
    let mut p = Vec::with_capacity(dir.len() + name.len() + 2);
    p.extend_from_slice(dir);
    if dir.last() != Some(&b'/') {
        p.push(b'/');
    }
    p.extend_from_slice(name);
    CString::new(p).ok()
}

fn walk<'s>(scope: &rayon::Scope<'s>, shared: &'s Shared<'s>, path: CString, dir_idx: u32) {
    #[cfg(test)]
    tests::inject_scan_fault(&path);
    // A stop leaves this directory unread: it is incomplete, and its
    // children, if any, were never listed.
    if shared.progress.stop_here() {
        shared.mark_incomplete(dir_idx);
        return;
    }
    // Nothing below runs another job on this thread (spawn only queues), so
    // the borrow can't nest.
    SCRATCH.with_borrow_mut(|s| {
        let progress = shared.progress;
        let Some(complete) = read_dir_bulk(&path, s, progress) else {
            shared.mark_incomplete(dir_idx);
            return;
        };
        let Scratch { entries, names, .. } = s;
        if entries.is_empty() {
            if !complete {
                shared.mark_incomplete(dir_idx);
            }
            return;
        }

        let mut n_files = 0u64;
        let mut n_dirs = 0u64;
        for e in entries.iter() {
            if !e.is_dir {
                n_files += 1;
                continue;
            }
            n_dirs += 1;
            if e.mount_point {
                progress.skipped_mount_points.fetch_add(1, Ordering::Relaxed);
            } else if e.dataless {
                progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
            }
        }

        let appended = {
            let mut arena = shared.arena.lock().unwrap();
            let t = &mut arena.tree;
            let limits = shared.limits;
            let fits = t.parents.len() as u64 + entries.len() as u64 <= limits.nodes
                && t.name_blob.len() as u64 + names.len() as u64 <= limits.name_bytes;
            if !fits {
                t.complete[dir_idx as usize] = false;
                None
            } else {
                t.complete[dir_idx as usize] = complete;
                let base = t.parents.len() as u32;
                t.parents.extend(std::iter::repeat_n(dir_idx, entries.len()));
                t.alloc.extend(entries.iter().map(|e| e.alloc));
                t.logical.extend(entries.iter().map(|e| e.size));
                t.flags.extend(entries.iter().map(|e| e.is_dir as u8));
                t.complete.extend(entries.iter().map(|e| !e.is_dir || e.descend()));
                let blob = t.name_blob.len() as u32;
                t.name_off.extend(entries.iter().map(|e| blob + e.name_end));
                t.name_blob.extend_from_slice(names);
                let mut bytes = 0;
                for (k, e) in entries.iter().enumerate() {
                    if !e.is_dir {
                        bytes += arena.account_file(base + k as u32, e.hardlink);
                    }
                }
                Some((base, bytes))
            }
        };
        let Some((base, bytes)) = appended else {
            progress.errors.fetch_add(1, Ordering::Relaxed);
            log_error(|| {
                format!(
                    "tree too large for the 32-bit layout; {} left unlisted",
                    path.to_string_lossy()
                )
            });
            return;
        };
        progress.files.fetch_add(n_files, Ordering::Relaxed);
        progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
        progress.bytes.fetch_add(bytes, Ordering::Relaxed);

        let mut start = 0;
        for (i, e) in entries.iter().enumerate() {
            if e.descend() {
                let idx = base + i as u32;
                match child_path(&path, &names[start..e.name_end as usize]) {
                    Some(child) => scope.spawn(move |sc| walk(sc, shared, child, idx)),
                    None => {
                        progress.errors.fetch_add(1, Ordering::Relaxed);
                        shared.mark_incomplete(idx);
                    }
                }
            }
            start = e.name_end as usize;
        }
    });
}

/// Each directory's children form one run of equal parents: `(parent, first, len)`.
fn runs(parents: &[u32]) -> Vec<(u32, u32, u32)> {
    let mut out = Vec::new();
    let mut i = 1;
    while i < parents.len() {
        let j = i + parents[i..].iter().take_while(|&&p| p == parents[i]).count();
        out.push((parents[i], i as u32, (j - i) as u32));
        i = j;
    }
    out
}

/// Derive subtree totals and the sorted child lists from the walk's arrays.
fn finish(t: &mut Tree) {
    // `complete` still holds each node's own state: record it before it is
    // folded into the subtree's.
    for (f, &c) in t.flags.iter_mut().zip(&t.complete) {
        if !c {
            *f |= SELF_INCOMPLETE;
        }
    }
    let runs = runs(&t.parents);
    // Bottom-up: a directory's run starts after its parent's run, so reverse
    // run order finishes every child before its parent.
    t.n_files = vec![0u32; t.len()];
    for &(p, first, len) in runs.iter().rev() {
        let (mut a, mut l, mut f, mut c) = (0u64, 0u64, 0u32, true);
        for i in first as usize..(first + len) as usize {
            a += t.alloc[i];
            l += t.logical[i];
            f += if t.is_dir(i) { t.n_files[i] } else { 1 };
            c &= t.complete[i];
        }
        let p = p as usize;
        t.alloc[p] += a;
        t.logical[p] += l;
        t.n_files[p] += f;
        t.complete[p] &= c;
    }
    link(t, &runs);
}

/// child_off and children, largest first (treemap layout order).
fn link(t: &mut Tree, runs: &[(u32, u32, u32)]) {
    let n = t.len();
    t.child_off = vec![0u32; n + 1];
    for &(p, _, len) in runs {
        t.child_off[p as usize] = len;
    }
    let mut acc = 0u32;
    for c in &mut t.child_off {
        (*c, acc) = (acc, acc + *c);
    }
    t.children = vec![0u32; n.saturating_sub(1)];
    for &(p, first, len) in runs {
        let at = t.child_off[p as usize] as usize;
        let kids = &mut t.children[at..at + len as usize];
        for (k, c) in kids.iter_mut().enumerate() {
            *c = first + k as u32;
        }
        kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.alloc[c as usize]));
    }
}

/// Hand-built trees for tests.
#[cfg(test)]
impl Tree {
    pub(crate) fn with_root(name: &str) -> Tree {
        let mut t = Tree { name_off: vec![0], ..Default::default() };
        t.push(name, NO_PARENT, 0, 0, true);
        t
    }
    /// Append a node as the walk does: each directory's children in one batch.
    pub(crate) fn push(&mut self, name: &str, parent: u32, logical: u64, alloc: u64, is_dir: bool) -> u32 {
        self.parents.push(parent);
        self.logical.push(logical);
        self.alloc.push(alloc);
        self.flags.push(is_dir as u8);
        self.complete.push(true);
        self.name_blob.extend_from_slice(name.as_bytes());
        self.name_off.push(self.name_blob.len() as u32);
        self.parents.len() as u32 - 1
    }
    /// Child lists only, keeping the sizes as given.
    pub(crate) fn link_children(&mut self) {
        let runs = runs(&self.parents);
        link(self, &runs);
    }
}

extern "C" {
    fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: c_int) -> c_int;
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;

/// # Safety
/// Only affects the calling thread's scheduling class.
pub unsafe fn set_thread_qos_user_interactive() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

const QOS_CLASS_USER_INITIATED: u32 = 0x19;

/// Rayon pool whose workers run at USER_INITIATED QoS. That still puts them
/// on the performance cores inside a GUI app (at the app's default QoS they
/// land on efficiency cores and scan twice as slowly), and it scans as fast
/// as USER_INTERACTIVE did, but it no longer outranks the UI and the system
/// compositor: at USER_INTERACTIVE a worker on every core made the window
/// (and screen recordings) skip frames for a quarter second mid-scan.
fn fast_pool() -> rayon::ThreadPool {
    rayon::ThreadPoolBuilder::new()
        .start_handler(|_| unsafe {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        })
        .build()
        .expect("thread pool")
}


/// The directory a scan of `p` reads: `p` made absolute with every symbolic
/// link in it followed, since the walk opens directories without following
/// links. The scan root and the CLI both resolve through this.
///
/// Each ancestor is checked before resolving deeper: canonicalize/read_dir on
/// a cloud-only directory can ask its provider to materialize that directory,
/// so a cloud-only path is refused instead.
pub fn local_path(p: &Path) -> Result<PathBuf, String> {
    local_path_at(p, 0)
}

fn local_path_at(p: &Path, depth: u32) -> Result<PathBuf, String> {
    use std::os::macos::fs::MetadataExt;
    use std::path::Component;
    if depth > 40 {
        return Err("Too many symbolic links in the scan root".into());
    }
    let absolute = if p.is_absolute() {
        p.to_owned()
    } else {
        std::env::current_dir().map_err(|e| e.to_string())?.join(p)
    };
    let mut resolved = PathBuf::from("/");
    let mut is_directory = true;
    for component in absolute.components() {
        if !is_directory {
            return Err(format!("Not a directory: {}", resolved.display()));
        }
        match component {
            Component::RootDir | Component::CurDir => continue,
            Component::ParentDir => {
                resolved.pop();
                continue;
            }
            Component::Normal(part) => resolved.push(part),
            _ => return Err("Unsupported path prefix".into()),
        }
        let m = std::fs::symlink_metadata(&resolved)
            .map_err(|e| format!("Cannot resolve {}: {e}", resolved.display()))?;
        if m.st_flags() & SF_DATALESS != 0 {
            return Err(format!(
                "Cloud-only path; refusing to materialize {}",
                resolved.display()
            ));
        }
        if m.file_type().is_symlink() {
            let target = std::fs::read_link(&resolved).map_err(|e| e.to_string())?;
            let target = if target.is_absolute() {
                target
            } else {
                resolved.parent().unwrap_or(Path::new("/")).join(target)
            };
            resolved = local_path_at(&target, depth + 1)?;
            is_directory = std::fs::metadata(&resolved)
                .map_err(|e| e.to_string())?
                .is_dir();
        } else {
            is_directory = m.is_dir();
        }
    }
    Ok(resolved)
}

/// Scan `root` and return the finished tree, ready for the UI. A symlinked
/// root is followed (see `local_path`); the root node keeps the name it was
/// given, as far as it is UTF-8 (the path that is read is always exact). A
/// root that cannot be resolved is counted as an error and left unread.
pub fn scan(root: &Path, progress: &Progress) -> Tree {
    scan_with(root, progress, Limits::ABI)
}

fn scan_with(root: &Path, progress: &Progress, limits: Limits) -> Tree {
    let root_name = root.to_string_lossy();
    let root_name = if u32::try_from(root_name.len()).is_ok() {
        root_name.as_bytes()
    } else {
        &[]
    };
    let tree = Tree {
        parents: vec![NO_PARENT],
        alloc: vec![0],
        logical: vec![0],
        flags: vec![1],
        complete: vec![true],
        name_off: vec![0, root_name.len() as u32],
        name_blob: root_name.to_vec(),
        ..Default::default()
    };
    let shared = Shared {
        arena: Mutex::new(Arena {
            tree,
            hardlinks: HashMap::new(),
        }),
        progress,
        limits,
    };

    let t0 = std::time::Instant::now();
    use std::os::macos::fs::MetadataExt;
    let root_is_cloud_only =
        std::fs::symlink_metadata(root).is_ok_and(|m| m.st_flags() & SF_DATALESS != 0);
    if root_is_cloud_only {
        progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
        shared.mark_incomplete(0);
    } else {
        let target = local_path(root).and_then(|resolved| {
            CString::new(resolved.as_os_str().as_encoded_bytes())
                .map_err(|_| "The scan root contains a NUL byte".to_string())
        });
        match target {
            Ok(path) => fast_pool().scope(|s| walk(s, &shared, path, 0)),
            Err(reason) => {
                progress.errors.fetch_add(1, Ordering::Relaxed);
                shared.mark_incomplete(0);
                log_error(|| format!("skip {} ({reason})", root.to_string_lossy()));
            }
        }
    }
    let t1 = std::time::Instant::now();
    let mut tree = shared.arena.into_inner().unwrap().tree;
    finish(&mut tree);
    tree.errors = progress.errors.load(Ordering::Relaxed);
    if std::env::var_os("BZ_TIMING").is_some() {
        eprintln!(
            "[bz] walk {:.3}s  finish {:.1}ms  ({} nodes)",
            (t1 - t0).as_secs_f64(),
            t1.elapsed().as_secs_f64() * 1e3,
            tree.len()
        );
    }
    tree
}

/// Count-only walk with no tree building: measures the pure syscall floor.
pub fn scan_count(root: &Path, progress: &Progress) {
    fn go<'s>(scope: &rayon::Scope<'s>, progress: &'s Progress, dir: CString) {
        SCRATCH.with_borrow_mut(|s| {
            if read_dir_bulk(&dir, s, progress).is_none() {
                return;
            }
            let (mut start, mut n_files, mut n_dirs, mut bytes) = (0, 0u64, 0u64, 0u64);
            for e in &s.entries {
                if e.is_dir {
                    n_dirs += 1;
                    if e.descend() {
                        if let Some(p) = child_path(&dir, &s.names[start..e.name_end as usize]) {
                            scope.spawn(move |sc| go(sc, progress, p));
                        }
                    }
                } else {
                    n_files += 1;
                    bytes += e.alloc;
                }
                start = e.name_end as usize;
            }
            progress.files.fetch_add(n_files, Ordering::Relaxed);
            progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
            progress.bytes.fetch_add(bytes, Ordering::Relaxed);
        });
    }
    if let Ok(path) = CString::new(root.as_os_str().as_encoded_bytes()) {
        rayon::scope(|s| go(s, progress, path));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bulk_record(name: impl AsRef<[u8]>, is_dir: bool, flags: u32, mount_status: u32, links: u32) -> Vec<u8> {
        let name = name.as_ref();
        let mut e = vec![0u8; 4];
        let common = ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID;
        let dir = if is_dir { ATTR_DIR_MOUNTSTATUS } else { 0 };
        let file = if is_dir {
            0
        } else {
            ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE
        };
        for value in [common, 0, dir, file, 0, 0] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        let name_ref = e.len();
        e.extend_from_slice(&[0u8; 8]);
        for value in [17u32, if is_dir { VDIR } else { 1 }, flags] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        e.extend_from_slice(&123456u64.to_le_bytes());
        if is_dir {
            e.extend_from_slice(&mount_status.to_le_bytes());
        } else {
            e.extend_from_slice(&links.to_le_bytes());
            e.extend_from_slice(&12345i64.to_le_bytes());
            e.extend_from_slice(&16384i64.to_le_bytes());
        }
        let name_offset = (e.len() - name_ref) as u32;
        e[name_ref..name_ref + 4].copy_from_slice(&name_offset.to_le_bytes());
        e[name_ref + 4..name_ref + 8].copy_from_slice(&(name.len() as u32 + 1).to_le_bytes());
        e.extend_from_slice(name);
        e.push(0);
        let len = e.len() as u32;
        e[..4].copy_from_slice(&len.to_le_bytes());
        e
    }

    #[test]
    fn bulk_parser_preserves_cloud_mount_and_hardlink_metadata() {
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        for (name, dir, flags, mount, links) in [
            ("cloud", true, SF_DATALESS, 0, 1),
            ("mounted", true, 0, DIR_MNTSTATUS_MNTPOINT, 1),
            ("plain", true, 0, 0, 1),
            ("linked-é", false, 0, 0, 2),
        ] {
            let record = bulk_record(name, dir, flags, mount, links);
            assert!(parse_entry(&record, &mut entries, &mut names, &Progress::default()));
        }
        assert_eq!(entries.len(), 4);
        assert!(entries[..3].iter().all(|e| e.is_dir) && !entries[3].is_dir);
        assert!(entries[0].dataless && !entries[0].mount_point);
        assert!(!entries[1].dataless && entries[1].mount_point);
        let descend: Vec<_> = entries.iter().map(|e| e.descend()).collect();
        assert_eq!(descend, [false, false, true, false], "cloud-only and mount points are skipped");
        assert_eq!(&names[entries[2].name_end as usize..], "linked-é".as_bytes());
        assert_eq!(entries[3].hardlink, Some((17, 123456)));
        assert_eq!((entries[3].size, entries[3].alloc), (12345, 16384));
    }

    /// Every child is listed once, under its parent, after it.
    fn assert_partition(t: &Tree) {
        let mut seen = vec![false; t.len()];
        seen[0] = true;
        for p in 0..t.len() {
            assert!(t.flags[p] & 1 != 0 || t.kids(p).is_empty());
            for &c in t.kids(p) {
                let c = c as usize;
                assert!(c > p, "aggregation requires parent-before-child order");
                assert!(!seen[c], "a child belongs to exactly one directory");
                seen[c] = true;
                assert_eq!(t.parents[c] as usize, p);
            }
        }
        assert!(seen.iter().all(|&v| v), "every node is reachable");
    }

    #[test]
    fn scan_preserves_parent_links_empty_dirs_and_symlinks() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("bz-tree-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("nested/empty")).unwrap();
        std::fs::write(root.join("nested/document-é"), [7u8; 17]).unwrap();
        symlink(&root, root.join("loop")).unwrap();
        let t = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        assert_eq!(t.len(), 5, "directory symlinks are not followed");
        assert_eq!(t.n_files[0], 2);
        assert_partition(&t);
        let find = |n: &str| (0..t.len()).find(|&i| t.name(i) == n).unwrap();
        let empty = find("empty");
        assert!(t.flags[empty] & 1 != 0 && t.kids(empty).is_empty());
        assert_eq!(t.logical[find("document-é")], 17);
    }

    #[test]
    fn parallel_child_ranges_partition_wide_and_deep_tree() {
        let root = std::env::temp_dir().join(format!("bz-ranges-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let mut deep = root.clone();
        for depth in 1..=96 {
            deep.push("d");
            std::fs::create_dir(&deep).unwrap();
            std::fs::write(deep.join("data"), vec![1u8; depth]).unwrap();
        }
        for width in 0..64 {
            let dir = root.join(format!("wide-{width}"));
            std::fs::create_dir_all(dir.join("empty")).unwrap();
            std::fs::write(dir.join("data"), [1u8; 19]).unwrap();
        }
        let t = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        assert_eq!(t.len(), 385);
        assert_eq!(t.n_files[0], 160);
        assert_eq!(t.logical[0], 5872);
        assert_partition(&t);
    }

    /// A tree as the walk leaves it: each directory's entries appended as one
    /// batch after it, totals and child lists not yet derived.
    fn fixture(dirs: usize, files_per_dir: usize) -> Tree {
        let mut t = Tree::with_root("/fixture");
        t.errors = 3;
        for dir in 0..dirs {
            t.push(&format!("directory-{dir}"), 0, 0, 0, true);
        }
        for dir in 0..dirs {
            for file in 0..files_per_dir {
                let size = (file as u64 * 7919 + dir as u64 * 104729) % 1_000_000;
                let name = format!("document-{dir}-{file}-é-日本語.txt");
                t.push(&name, dir as u32 + 1, size, size.div_ceil(4096) * 4096, false);
            }
        }
        // One unreadable directory, to exercise incompleteness propagation.
        if dirs > 1 {
            t.complete[2] = false;
        }
        t
    }

    /// The pre-0.6 conversion, kept as an independent reference: per-node
    /// totals in reverse index order, then each child list sorted on its own.
    fn reference_finish(mut t: Tree) -> Tree {
        let n = t.len();
        for i in 0..n {
            if !t.complete[i] {
                t.flags[i] |= SELF_INCOMPLETE;
            }
        }
        t.n_files = vec![0; n];
        let mut lists = vec![Vec::new(); n];
        for i in (1..n).rev() {
            let p = t.parents[i] as usize;
            t.alloc[p] += t.alloc[i];
            t.logical[p] += t.logical[i];
            t.n_files[p] += if t.flags[i] & 1 != 0 { t.n_files[i] } else { 1 };
            t.complete[p] &= t.complete[i];
        }
        for i in 1..n {
            lists[t.parents[i] as usize].push(i as u32);
        }
        t.child_off = vec![0];
        for mut kids in lists {
            kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.alloc[c as usize]));
            t.children.extend(kids);
            t.child_off.push(t.children.len() as u32);
        }
        t
    }

    #[test]
    fn finish_preserves_every_abi_column_and_child_order() {
        for (dirs, files) in [(0, 0), (3, 0), (1, 1024), (128, 4)] {
            let mut t = fixture(dirs, files);
            finish(&mut t);
            assert_eq!(t, reference_finish(fixture(dirs, files)));
        }
    }

    #[test]
    #[ignore = "isolated performance measurement; run in release with --nocapture"]
    fn finish_benchmark() {
        // Alternate execution order to avoid favoring either implementation.
        for round in 0..10 {
            for variant in [round % 2, 1 - round % 2] {
                let mut t = fixture(256, 1024);
                let start = std::time::Instant::now();
                if variant == 0 {
                    t = reference_finish(t);
                } else {
                    finish(&mut t);
                }
                let elapsed = start.elapsed();
                std::hint::black_box(&t);
                println!("finish,{round},{variant},{}", elapsed.as_nanos());
            }
        }
    }

    #[test]
    fn hardlink_owner_does_not_depend_on_discovery_order() {
        for order in [[3, 4, 5], [5, 3, 4], [4, 5, 3]] {
            let mut tree = Tree::with_root("/root");
            tree.push("a", 0, 0, 0, true);
            tree.push("z", 0, 0, 0, true);
            tree.push("a", 2, 8192, 4096, false);
            tree.push("z", 1, 8192, 4096, false);
            tree.push("y", 1, 8192, 4096, false);
            let mut arena = Arena { tree, hardlinks: HashMap::new() };
            let added: u64 = order
                .into_iter()
                .map(|i| arena.account_file(i, Some((7, 42))))
                .sum();
            let t = &mut arena.tree;
            assert_eq!(added, 4096, "progress counts the inode once");
            assert_eq!(t.alloc[3], 0); // /root/z/a
            assert_eq!(t.alloc[4], 0); // /root/a/z
            assert_eq!(t.alloc[5], 4096); // /root/a/y wins every time
            assert_eq!(t.logical[5], 8192);
            finish(t);
            assert_eq!((t.alloc[0], t.logical[0], t.n_files[0]), (4096, 8192, 3));
        }
    }

    #[test]
    fn incomplete_subtrees_propagate_without_hiding_healthy_siblings() {
        let mut t = Tree::with_root("/root");
        t.push("partial", 0, 0, 0, true);
        t.push("healthy", 0, 0, 0, true);
        let skipped = t.push("unreadable-or-skipped", 1, 0, 0, true);
        t.push("file", 2, 8192, 4096, false);
        t.complete[skipped as usize] = false;
        finish(&mut t);
        assert_eq!(t.complete[..3], [false, false, true]);
        assert_eq!(t.alloc[0], 4096, "partial scans still expose observed bytes");
    }

    #[test]
    fn entry_errors_are_reported_instead_of_silently_dropped() {
        let mut bytes = vec![0u8; 28];
        bytes[4..8].copy_from_slice(&ATTR_CMN_ERROR.to_le_bytes());
        bytes[24..28].copy_from_slice(&(libc::EACCES as u32).to_le_bytes());
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_entry(&bytes, &mut entries, &mut names, &progress));
        assert!(entries.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.entry_errors.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn invalid_utf8_is_not_replaced_with_an_actionable_path() {
        let mut bytes = vec![0u8; 34];
        bytes[4..8].copy_from_slice(&ATTR_CMN_NAME.to_le_bytes());
        bytes[24..28].copy_from_slice(&8u32.to_le_bytes());
        bytes[28..32].copy_from_slice(&2u32.to_le_bytes());
        bytes[32] = 0xff;
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_entry(&bytes, &mut entries, &mut names, &progress));
        assert!(entries.is_empty() && names.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.invalid_names.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn hardlinks_count_once() {
        let root = std::env::temp_dir().join(format!("bz-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("file"), vec![7u8; 1 << 20]).unwrap();
        std::fs::hard_link(root.join("file"), root.join("sub/link")).unwrap();

        let tree = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(tree.n_files[0], 2, "both names are listed");
        assert_eq!(tree.logical[0], 1 << 20, "but the bytes count once");
    }

    #[test]
    fn flat_layout() {
        let root = std::env::temp_dir().join(format!("bz-test-flat-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("big/deep")).unwrap();
        std::fs::create_dir_all(root.join("empty")).unwrap();
        std::fs::write(root.join("big/deep/blob"), vec![1u8; 1 << 20]).unwrap();
        std::fs::write(root.join("small"), b"hi").unwrap();

        let t = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(t.len(), 6);
        assert_eq!((t.child_off.len(), t.name_off.len(), t.children.len()), (7, 7, 5));
        let names = |i: usize| t.kids(i).iter().map(|&c| t.name(c as usize)).collect::<Vec<_>>();
        assert_eq!(names(0), ["big", "small", "empty"], "largest first");
        let big = t.kids(0)[0] as usize;
        assert_eq!(names(big), ["deep"]);
        assert_eq!((t.n_files[0], t.n_files[big]), (2, 1));
        assert_eq!(t.logical[0], (1 << 20) + 2);
        assert_eq!(t.flags[big], 1);
        for i in 1..t.len() {
            assert!(t.kids(t.parents[i] as usize).contains(&(i as u32)));
        }
    }

    #[test]
    fn c_abi_round_trip() {
        use ffi::*;
        let root = std::env::temp_dir().join(format!("bz-test-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("d")).unwrap();
        std::fs::write(root.join("d/f"), b"x").unwrap();
        let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();

        unsafe {
            let h = bz_scan_start(path.as_ptr());
            let (mut f, mut d, mut b, mut done) = (0, 0, 0, 0);
            while done == 0 {
                std::thread::sleep(std::time::Duration::from_millis(1));
                bz_progress(h, &mut f, &mut d, &mut b, &mut done);
            }
            let _ = std::fs::remove_dir_all(&root);
            assert_eq!(bz_take_tree(h), 3);
            let s = |p: *const u32, n| std::slice::from_raw_parts(p, n);
            assert_eq!(s(bz_parents(h), 3), [NO_PARENT, 0, 1]);
            assert_eq!(s(bz_child_off(h), 4), [0, 1, 2, 2]);
            assert_eq!(s(bz_children(h), 2), [1, 2]);
            assert_eq!(s(bz_nfiles(h), 3), [1, 1, 0]);
            let off = s(bz_name_off(h), 4);
            let blob = std::slice::from_raw_parts(bz_name_blob(h), off[3] as usize);
            assert_eq!(&blob[off[1] as usize..], b"df");
            bz_free(h);
        }
    }

    thread_local! {
        static INTERRUPTS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
    }

    fn interrupt_next(n: u32) {
        INTERRUPTS.with(|c| c.set(n));
    }

    pub(super) fn take_injected_interrupt() -> bool {
        INTERRUPTS.with(|c| {
            let left = c.get();
            c.set(left.saturating_sub(1));
            left > 0
        })
    }

    pub(crate) const PANIC_MARKER: &str = "bz-inject-panic";

    pub(super) fn inject_scan_fault(path: &CStr) {
        let marker = PANIC_MARKER.as_bytes();
        if path.to_bytes().windows(marker.len()).any(|w| w == marker) {
            panic!("injected scan fault");
        }
    }

    #[test]
    fn interrupted_calls_are_retried_a_bounded_number_of_times() {
        let calls = std::cell::Cell::new(0u32);
        let interrupted = |until: u32| {
            calls.set(0);
            retry_interrupted(|| {
                calls.set(calls.get() + 1);
                if calls.get() <= until {
                    unsafe { *libc::__error() = libc::EINTR };
                    -1
                } else {
                    7
                }
            })
        };
        assert_eq!(interrupted(0), 7);
        assert_eq!(interrupted(MAX_INTERRUPTS), 7, "the last allowed retry succeeds");
        assert_eq!(calls.get(), MAX_INTERRUPTS + 1);
        assert_eq!(interrupted(MAX_INTERRUPTS + 1), -1, "gives up after the bound");
        assert_eq!(calls.get(), MAX_INTERRUPTS + 1);
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::EINTR));
        calls.set(0);
        let n = retry_interrupted(|| {
            calls.set(calls.get() + 1);
            unsafe { *libc::__error() = libc::EACCES };
            -1
        });
        assert_eq!((n, calls.get()), (-1, 1));
    }

    #[test]
    fn an_interrupted_directory_read_is_retried_instead_of_reported_partial() {
        let root = std::env::temp_dir().join(format!("bz-test-eintr-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for name in ["a", "b", "c"] {
            std::fs::write(root.join(name), b"x").unwrap();
        }
        let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();

        let (mut scratch, progress) = (Scratch::default(), Progress::default());
        interrupt_next(3);
        assert_eq!(read_dir_bulk(&path, &mut scratch, &progress), Some(true));
        assert_eq!(scratch.entries.len(), 3);
        assert_eq!(progress.errors.load(Ordering::Relaxed), 0);

        interrupt_next(1000);
        assert_eq!(read_dir_bulk(&path, &mut scratch, &progress), Some(false));
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        interrupt_next(0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_symlinked_root_is_scanned_through_the_link() {
        let base = std::env::temp_dir().join(format!("bz-test-symroot-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("real/sub")).unwrap();
        std::fs::write(base.join("real/sub/f"), b"x").unwrap();
        std::os::unix::fs::symlink(base.join("real"), base.join("abs")).unwrap();
        std::os::unix::fs::symlink("real", base.join("rel")).unwrap();
        std::os::unix::fs::symlink("rel", base.join("chain")).unwrap();

        for link in ["abs", "rel", "chain"] {
            let progress = Progress::default();
            let t = scan(&base.join(link), &progress);
            assert_eq!(t.len(), 3, "{link}: root, sub, f");
            assert_eq!(t.errors, 0, "{link}");
            assert!(t.complete[0], "{link}");
            assert_eq!(t.name(0), base.join(link).to_str().unwrap(), "the root keeps the name it was given");
            assert_eq!(t.name(2), "f");
        }

        std::os::unix::fs::symlink("loop", base.join("loop")).unwrap();
        std::os::unix::fs::symlink("nowhere", base.join("dangling")).unwrap();
        std::os::unix::fs::symlink("real/sub/f", base.join("to_file")).unwrap();
        for link in ["loop", "dangling", "to_file"] {
            let t = scan(&base.join(link), &Progress::default());
            assert_eq!((t.len(), t.errors, t.complete[0]), (1, 1, false), "{link}");
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn local_path_resolves_every_link_and_dot_segment() {
        let base = std::fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("bz-test-local-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("a/b")).unwrap();
        std::os::unix::fs::symlink("..", base.join("a/b/up")).unwrap();
        assert_eq!(local_path(&base.join("a/b/up/./b/../b")).unwrap(), base.join("a/b"));
        assert!(local_path(&base.join("missing")).is_err());
        let _ = std::fs::remove_dir_all(&base);
    }

    fn limit_fixture(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("s")).unwrap();
        for f in ["f1", "f2", "f3", "f4", "s/g1", "s/g2"] {
            std::fs::write(root.join(f), b"x").unwrap();
        }
        root
    }

    #[test]
    fn past_the_abi_limits_a_directory_is_left_unlisted_and_incomplete() {
        let root = limit_fixture("bz-test-limits");
        let label = root.to_str().unwrap().len() as u64;
        let full = scan(&root, &Progress::default());
        assert_eq!(full.len(), 8);
        assert!(full.complete[0] && full.errors == 0);

        let progress = Progress::default();
        let t = scan_with(&root, &progress, Limits { nodes: 6, name_bytes: u32::MAX as u64 });
        assert_eq!(t.len(), 6, "s's listing is dropped whole, not cut");
        assert!(!t.complete[0], "the tree is marked incomplete");
        let s = (0..t.len()).find(|&i| t.name(i) == "s").unwrap();
        assert!(!t.complete[s] && t.kids(s).is_empty());
        assert_eq!(t.errors, 1);
        assert_eq!(progress.files.load(Ordering::Relaxed), 4, "dropped entries are not counted as scanned");
        assert_eq!(t.n_files[0], 4);
        assert_partition(&t);

        let t = scan_with(&root, &Progress::default(), Limits { nodes: u32::MAX as u64, name_bytes: label + 9 });
        assert_eq!(t.len(), 6);
        assert!(!t.complete[0]);
        assert_eq!(t.errors, 1);
        assert_eq!(*t.name_off.last().unwrap() as u64, label + 9);

        let t = scan_with(&root, &Progress::default(), Limits { nodes: 3, name_bytes: u32::MAX as u64 });
        assert_eq!((t.len(), t.complete[0], t.errors), (1, false, 1));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_walk_that_panics_reaches_the_caller_of_scan() {
        let root = std::env::temp_dir().join(format!("{PANIC_MARKER}-lib-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let outcome = std::panic::catch_unwind(|| scan(&root, &Progress::default()));
        assert!(outcome.is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    fn wide_fixture(name: &str, fan: usize, files: usize) -> PathBuf {
        let root = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for a in 0..fan {
            for b in 0..fan {
                let dir = root.join(format!("a{a}/b{b}"));
                std::fs::create_dir_all(&dir).unwrap();
                for f in 0..files {
                    std::fs::write(dir.join(format!("f{f}")), b"x").unwrap();
                }
            }
        }
        root
    }

    fn assert_unread_folders_are_incomplete(t: &Tree) {
        assert!(!t.complete[0], "a tree cut short is not complete");
        for i in (0..t.len()).filter(|&i| t.is_dir(i) && t.kids(i).is_empty()) {
            assert!(!t.complete[i], "folder {i} was never listed but reads as complete");
        }
    }

    #[test]
    fn cancel_stops_a_large_walk_early_and_marks_what_it_left() {
        let root = wide_fixture("bz-test-cancel-wide", 40, 3);
        let full = scan(&root, &Progress::default());
        assert!(full.complete[0] && full.len() > 6000);

        let progress = Progress { cancel_after_dirs: AtomicU64::new(25), ..Default::default() };
        let started = std::time::Instant::now();
        let t = scan(&root, &progress);
        let took = started.elapsed();
        assert!(progress.is_cancelled() && progress.stopped_early());
        assert!(t.len() < full.len() / 2, "{} of {} nodes: the walk went on after the stop", t.len(), full.len());
        assert_unread_folders_are_incomplete(&t);
        assert_partition(&t);
        assert!(took < std::time::Duration::from_secs(5), "took {took:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_before_the_first_folder_reads_nothing() {
        let root = limit_fixture("bz-test-cancel-first");
        let progress = Progress::default();
        progress.cancel();
        progress.cancel();
        let t = scan(&root, &progress);
        assert!(progress.stopped_early());
        assert_eq!(t.len(), 1, "not even the root was listed");
        assert_unread_folders_are_incomplete(&t);
        assert_eq!(progress.files.load(Ordering::Relaxed), 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_after_the_walk_leaves_a_whole_tree_alone() {
        let root = limit_fixture("bz-test-cancel-after");
        let progress = Progress::default();
        let t = scan(&root, &progress);
        progress.cancel();
        assert!(!progress.stopped_early(), "nothing was left unread");
        assert!(t.complete[0] && t.errors == 0 && t.len() == 8);
        assert!(Coverage::of(&progress, &t).complete);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_does_not_wait_for_the_end_of_a_huge_folder() {
        let root = std::env::temp_dir().join(format!("bz-test-cancel-huge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for i in 0..12_000 {
            std::fs::write(root.join(format!("a-rather-long-file-name-to-fill-the-buffer-{i:06}")), b"").unwrap();
        }
        let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();
        let mut scratch = Scratch::default();

        let all = read_dir_bulk(&path, &mut scratch, &Progress::default());
        assert_eq!((all, scratch.entries.len()), (Some(true), 12_000));

        let progress = Progress::default();
        progress.cancel();
        let cut = read_dir_bulk(&path, &mut scratch, &progress);
        assert_eq!(cut, Some(false), "the listing is partial");
        assert!(progress.stopped_early());
        assert!(!scratch.entries.is_empty() && scratch.entries.len() < 12_000);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn coverage_is_the_one_account_the_cli_and_the_app_read() {
        let root = limit_fixture("bz-test-coverage");
        let progress = Progress::default();
        let t = scan(&root, &progress);
        let whole = Coverage::of(&progress, &t);
        assert_eq!(whole, Coverage { complete: true, ..Default::default() });

        let progress = Progress::default();
        for (n, counter) in [
            &progress.entry_errors,
            &progress.invalid_names,
            &progress.skipped_cloud_dirs,
            &progress.skipped_mount_points,
        ]
        .into_iter()
        .enumerate()
        {
            counter.store(n as u64 + 10, Ordering::Relaxed);
        }
        let mut cut = Tree { errors: 3, ..Tree::with_root("/x") };
        cut.complete[0] = false;
        let c = Coverage::of(&progress, &cut);
        assert_eq!((c.errors, c.complete), (3, false));
        assert_eq!(
            [
                c.entry_errors,
                c.invalid_names,
                c.skipped_cloud_directories,
                c.skipped_mount_points,
            ],
            [10, 11, 12, 13]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_entry_with_a_name_that_is_not_utf8_is_counted_and_its_folder_reads_partial() {
        let mut batch = bulk_record("ok", true, 0, 0, 1);
        batch.extend(bulk_record(b"bad-\xff\xfe", true, 0, 0, 1));
        batch.extend(bulk_record("f", false, 0, 0, 1));
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        let complete = parse_batch(&batch, 3, &mut entries, &mut names, &progress, c"/dir");
        assert!(!complete, "a dropped entry makes its directory partial");
        assert_eq!(entries.len(), 2, "the entries around it are kept");
        assert_eq!(names, b"okf");
        assert_eq!(progress.invalid_names.load(Ordering::Relaxed), 1);
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);

        let mut tree = Tree::with_root("/dir");
        tree.complete[0] = complete;
        tree.errors = progress.errors.load(Ordering::Relaxed);
        let c = Coverage::of(&progress, &tree);
        assert_eq!((c.complete, c.invalid_names, c.errors), (false, 1, 1));

        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_batch(&batch[..batch.len() - 3], 3, &mut entries, &mut names, &progress, c"/dir"));
        assert_eq!(progress.entry_errors.load(Ordering::Relaxed), 1);
    }
}
