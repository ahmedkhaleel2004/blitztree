//! Ultra-fast APFS directory tree scanner using getattrlistbulk(2).
//!
//! getattrlistbulk returns a whole batch of directory entries *with* their
//! metadata (name, type, sizes) per syscall, so we never pay the classic
//! readdir-then-stat-per-file cost that makes naive scanners slow on macOS.

pub mod cache;
pub mod cleanup;
pub mod ffi;
pub mod searchfs;

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

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
    fn getattrlist(
        path: *const c_char,
        attr_list: *mut AttrList,
        attr_buf: *mut c_void,
        attr_buf_size: usize,
        options: u32,
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
/// Extended common attributes: requested in `forkattr`, and only with this option.
const FSOPT_ATTR_CMN_EXTENDED: u32 = 0x0000_0020;
const FSOPT_NOFOLLOW: u32 = 0x0000_0001;
const ATTR_CMNEXT_PRIVATESIZE: u32 = 0x0000_0008;
const ATTR_CMNEXT_CLONEID: u32 = 0x0000_0100;
const ATTR_CMNEXT_EXT_FLAGS: u32 = 0x0000_0200;
/// sys/stat.h: the file may share blocks with another file (an APFS clone).
const EF_MAY_SHARE_BLOCKS: u64 = 0x0000_0001;
/// sys/stat.h: the file shares all of its blocks with another file.
const EF_SHARES_ALL_BLOCKS: u64 = 0x0000_0040;

const VDIR: u32 = 2;
/// Contents live in the cloud (iCloud Drive, File Provider). Opening such a
/// directory asks the provider to materialize it, i.e. download.
const SF_DATALESS: u32 = 0x4000_0000;

const BUF_SIZE: usize = 256 * 1024;

// ---- Tree model ----

/// Bump whenever a scan counts, attributes or flags sizes differently, so
/// results saved by an older build (see `cache`) are not shown as current.
/// 1: APFS clones count once, toward the lowest file id.
pub const SIZE_RULES: u32 = 1;

pub const NO_PARENT: u32 = u32::MAX;

/// The finished tree as flat arrays, the layout the Swift UI reads in place
/// (see app/bz.h). Node 0 is the root; children come after their parent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CloneGroup {
    pub end: u32,
    /// Bytes every member shares, counted once (toward the first member).
    pub shared: u64,
}

#[derive(Default)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
pub struct Tree {
    pub parents: Vec<u32>,
    /// Allocated (on-disk) bytes; subtree totals for directories.
    pub alloc: Vec<u64>,
    /// Allocated bytes with APFS clones counted once: the blocks a family of
    /// clones shares count toward one member, the other members count none.
    /// Subtree totals for directories. `alloc - unique` is a node's cloned bytes.
    pub unique: Vec<u64>,
    /// Logical bytes; subtree totals for directories.
    pub logical: Vec<u64>,
    /// Subtree file count for directories, 0 for files.
    pub n_files: Vec<u32>,
    pub flags: Vec<u8>, // bit0 = is_dir
    /// False when an entry was unreadable or a cloud/mount boundary was skipped
    /// anywhere in this subtree. The observed sizes then describe a partial walk.
    pub complete: Vec<bool>,
    /// Node i's children are children[child_off[i]..child_off[i + 1]],
    /// largest unique size first (treemap layout order).
    pub child_off: Vec<u32>,
    pub children: Vec<u32>,
    /// Node i's name is name_blob[name_off[i]..name_off[i + 1]], UTF-8.
    pub name_off: Vec<u32>,
    pub name_blob: Vec<u8>,
    /// Files that share all of their blocks with APFS clones, by clone
    /// family: group g is clone_members[clone_groups[g - 1].end..clone_groups[g].end],
    /// the member counted with the shared bytes first.
    pub clone_members: Vec<u32>,
    pub clone_groups: Vec<CloneGroup>,
    /// Files that share only some of their blocks, with a file they were
    /// cloned from or into. That file is unknown, so these count in full.
    pub partial_clones: Vec<u32>,
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
    /// Bytes this node shares with APFS clones that are counted elsewhere.
    pub fn cloned(&self, i: usize) -> u64 {
        self.alloc[i] - self.unique[i]
    }
    /// What deleting each of `roots` (disjoint subtrees) would free, as far as
    /// APFS clones go: for files that share blocks with a clone, only their
    /// private size counts. Shared blocks never count as freed, even when every
    /// clone the scan found is inside, because a clone that has since been
    /// changed (outside the scan or not) can still hold them and APFS doesn't
    /// say which file it is. Asks the file system for private sizes, so call it
    /// off the main thread; an unknown private size counts as not freed. Hard
    /// links and snapshots are not considered.
    pub fn reclaimable(&self, roots: &[u32]) -> Vec<u64> {
        self.reclaimable_with(roots, private_size)
    }
    /// `reclaimable`, with `private` giving each partly cloned file's private
    /// size. A tree loaded from a saved scan passes `|_| None`, so showing it
    /// doesn't read the disk while the fresh scan runs.
    pub fn reclaimable_with(&self, roots: &[u32], private: impl Fn(&Path) -> Option<u64>) -> Vec<u64> {
        let mut out: Vec<u64> = roots.iter().map(|&r| self.unique[r as usize]).collect();
        let slot: HashMap<u32, usize> = roots.iter().enumerate().map(|(k, &r)| (r, k)).collect();
        let inside = |mut i: u32| loop {
            if let Some(&k) = slot.get(&i) {
                return Some(k);
            }
            if i == NO_PARENT {
                return None;
            }
            i = self.parents[i as usize];
        };
        // Full clones have no private blocks: take the shared bytes back off
        // the member that counted them.
        let mut start = 0;
        for g in &self.clone_groups {
            let owner = self.clone_members[start as usize];
            start = g.end;
            if let Some(k) = inside(owner) {
                out[k] -= g.shared.min(out[k]);
            }
        }
        for &i in &self.partial_clones {
            let Some(k) = inside(i) else { continue };
            let private = private(&self.path(i as usize)).unwrap_or(0);
            out[k] -= self.unique[i as usize].saturating_sub(private).min(out[k]);
        }
        out
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
    /// Set when the file may share blocks with an APFS clone.
    clone: Option<CloneInfo>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CloneInfo {
    /// `(device, clone id)`. Full clones of one file share its clone id; a
    /// clone that has since been changed gets its own.
    key: (u32, u64),
    file_id: u64,
    /// Every block is shared with another file (so none is private).
    shares_all: bool,
}

/// The bytes of `path` no other file shares (ATTR_CMNEXT_PRIVATESIZE), read
/// with getattrlist(2).
fn private_size(path: &Path) -> Option<u64> {
    let attr = ATTR_CMNEXT_PRIVATESIZE;
    let path = CString::new(path.as_os_str().as_encoded_bytes()).ok()?;
    let mut attrlist = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS,
        volattr: 0,
        dirattr: 0,
        fileattr: 0,
        forkattr: attr,
    };
    let mut buf = [0u8; 4 + 20 + 8];
    let options = FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW;
    let status = unsafe {
        getattrlist(path.as_ptr(), &mut attrlist, buf.as_mut_ptr() as *mut c_void, buf.len(), options)
    };
    if status != 0 || u32_at(&buf, 4 + 16) & attr == 0 {
        return None;
    }
    // An off_t, after the length and the returned attribute set.
    Some(i64_at(&buf, 24).max(0) as u64)
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
        if std::env::var_os("BZ_LOG_ERRORS").is_some() {
            eprintln!(
                "[bz] skip {} ({})",
                path.to_string_lossy(),
                std::io::Error::last_os_error()
            );
        }
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
        // Extended common attributes; volumes other than APFS leave them out.
        // PRIVATESIZE is not asked for here: it made scans 3x slower, and
        // EXT_FLAGS already says when a file shares all of its blocks.
        forkattr: ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS,
    };

    let mut complete = true;
    loop {
        let n = unsafe {
            getattrlistbulk(
                fd,
                &mut attrlist,
                s.buf.as_mut_ptr() as *mut c_void,
                BUF_SIZE,
                FSOPT_ATTR_CMN_EXTENDED as u64,
            )
        };
        if n <= 0 {
            if n < 0 {
                progress.errors.fetch_add(1, Ordering::Relaxed);
                complete = false;
            }
            break;
        }
        let mut off = 0usize;
        for _ in 0..n {
            let len = u32_at(&s.buf, off) as usize;
            complete &= parse_entry(&s.buf[off..off + len], &mut s.entries, &mut s.names, progress);
            off += len;
        }
    }
    unsafe { libc::close(fd) };
    Some(complete)
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
/// TOTALSIZE, ALLOCSIZE), then extended common attrs (CLONEID, EXT_FLAGS).
/// Dir attrs come back only for directories and file attrs only for files.
/// False (and counted) if the entry had to be dropped.
fn parse_entry(e: &[u8], out: &mut Vec<Entry>, names: &mut Vec<u8>, progress: &Progress) -> bool {
    let mut off = 4usize; // skip length
    let ret_common = u32_at(e, off);
    let ret_dir = u32_at(e, off + 8);
    let ret_file = u32_at(e, off + 12);
    let ret_ext = u32_at(e, off + 16);
    off += 20; // attribute_set_t: 5 x u32

    if ret_common & ATTR_CMN_ERROR != 0 {
        let err = u32_at(e, off);
        off += 4;
        if err != 0 {
            progress.entry_errors.fetch_add(1, Ordering::Relaxed);
            progress.errors.fetch_add(1, Ordering::Relaxed);
            return false;
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
        let start = (off as isize + data_off) as usize;
        // data_len includes the trailing NUL
        name = &e[start..start + data_len.saturating_sub(1)];
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
        off += 8;
    }

    let mut clone_id = None;
    if ret_ext & ATTR_CMNEXT_CLONEID != 0 {
        clone_id = Some(u64_at(e, off));
        off += 8;
    }
    let mut ext_flags = 0u64;
    if ret_ext & ATTR_CMNEXT_EXT_FLAGS != 0 {
        ext_flags = u64_at(e, off);
    }
    let clone = match clone_id {
        Some(id) if !is_dir && ext_flags & EF_MAY_SHARE_BLOCKS != 0 => Some(CloneInfo {
            key: (dev, id),
            file_id,
            shares_all: ext_flags & EF_SHARES_ALL_BLOCKS != 0,
        }),
        _ => None,
    };

    if name.is_empty() {
        return invalid_name();
    }
    names.extend_from_slice(name);
    out.push(Entry {
        name_end: names.len() as u32,
        is_dir,
        dataless: flags & SF_DATALESS != 0,
        mount_point,
        size,
        alloc,
        hardlink: (!is_dir && links > 1).then_some((dev, file_id)),
        clone,
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
    /// Files that may share blocks with a clone, resolved by `finish`.
    clones: Vec<(CloneInfo, u32)>,
    /// Clone families seen so far, so progress counts shared bytes once.
    clone_keys: HashSet<(u32, u64)>,
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

struct Shared<'a> {
    arena: Mutex<Arena>,
    progress: &'a Progress,
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
        progress.files.fetch_add(n_files, Ordering::Relaxed);
        progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);

        let (base, bytes) = {
            let mut arena = shared.arena.lock().unwrap();
            let t = &mut arena.tree;
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
                if e.is_dir {
                    continue;
                }
                let i = base + k as u32;
                let added = arena.account_file(i, e.hardlink);
                if let Some(c) = e.clone {
                    arena.clones.push((c, i));
                    let counted = !c.shares_all || arena.clone_keys.insert(c.key);
                    bytes += if counted { added } else { 0 };
                } else {
                    bytes += added;
                }
            }
            (base, bytes)
        };
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

/// Per-file unique sizes. A family of full clones counts its shared bytes
/// once, toward the member with the lowest file id (so the result doesn't
/// depend on scan order), and its other members count none. Files sharing
/// only some blocks count in full. Hard-link names that `account_file`
/// zeroed are not members.
fn count_clones_once(t: &mut Tree, mut clones: Vec<(CloneInfo, u32)>) {
    t.unique = t.alloc.clone();
    t.clone_members.clear();
    t.clone_groups.clear();
    t.partial_clones.clear();
    clones.retain(|&(_, i)| t.alloc[i as usize] > 0);
    clones.sort_unstable_by_key(|&(c, i)| (!c.shares_all, c.key, c.file_id, i));
    for group in clones.chunk_by(|a, b| (a.0.shares_all, a.0.key) == (b.0.shares_all, b.0.key)) {
        if !group[0].0.shares_all {
            t.partial_clones.extend(group.iter().map(|&(_, i)| i));
            continue;
        }
        let shared = t.alloc[group[0].1 as usize];
        for &(_, i) in &group[1..] {
            t.unique[i as usize] = t.alloc[i as usize].saturating_sub(shared);
        }
        t.clone_members.extend(group.iter().map(|&(_, i)| i));
        t.clone_groups.push(CloneGroup { end: t.clone_members.len() as u32, shared });
    }
}

/// Derive subtree totals and the sorted child lists from the walk's arrays.
fn finish(t: &mut Tree, clones: Vec<(CloneInfo, u32)>) {
    count_clones_once(t, clones);
    total_and_link(t);
}

/// Folder totals (alloc, unique, logical, n_files, complete) from each
/// file's own values, then the child lists. Folders' own sizes must be zero.
/// Every node's parent must come before it, and each folder's children must
/// be one contiguous run.
fn total_and_link(t: &mut Tree) {
    let runs = runs(&t.parents);
    // Bottom-up: a directory's run starts after its parent's run, so reverse
    // run order finishes every child before its parent.
    t.n_files = vec![0u32; t.len()];
    for &(p, first, len) in runs.iter().rev() {
        let (mut a, mut u, mut l, mut f, mut c) = (0u64, 0u64, 0u64, 0u32, true);
        for i in first as usize..(first + len) as usize {
            a += t.alloc[i];
            u += t.unique[i];
            l += t.logical[i];
            f += if t.is_dir(i) { t.n_files[i] } else { 1 };
            c &= t.complete[i];
        }
        let p = p as usize;
        t.alloc[p] += a;
        t.unique[p] += u;
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
        kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.unique[c as usize]));
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
        self.unique.push(alloc);
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


/// Scan `root` and return the finished tree, ready for the UI.
pub fn scan(root: &Path, progress: &Progress) -> Tree {
    let root_name = root.to_string_lossy();
    let tree = Tree {
        parents: vec![NO_PARENT],
        alloc: vec![0],
        logical: vec![0],
        flags: vec![1],
        complete: vec![true],
        name_off: vec![0, root_name.len() as u32],
        name_blob: root_name.as_bytes().to_vec(),
        ..Default::default()
    };
    let shared = Shared {
        arena: Mutex::new(Arena {
            tree,
            hardlinks: HashMap::new(),
            clones: Vec::new(),
            clone_keys: HashSet::new(),
        }),
        progress,
    };

    let t0 = std::time::Instant::now();
    use std::os::macos::fs::MetadataExt;
    let root_is_cloud_only =
        std::fs::symlink_metadata(root).is_ok_and(|m| m.st_flags() & SF_DATALESS != 0);
    if root_is_cloud_only {
        progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
        shared.mark_incomplete(0);
    } else if let Ok(path) = CString::new(root.as_os_str().as_encoded_bytes()) {
        fast_pool().scope(|s| walk(s, &shared, path, 0));
    } else {
        progress.errors.fetch_add(1, Ordering::Relaxed);
        shared.mark_incomplete(0);
    }
    let t1 = std::time::Instant::now();
    let Arena { mut tree, clones, .. } = shared.arena.into_inner().unwrap();
    finish(&mut tree, clones);
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

    /// `extended`: (clone id, extended flags), as APFS returns them.
    fn bulk_record(
        name: &str,
        is_dir: bool,
        flags: u32,
        mount_status: u32,
        links: u32,
        extended: Option<(u64, u64)>,
    ) -> Vec<u8> {
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
        let ext = if extended.is_some() {
            ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS
        } else {
            0
        };
        for value in [common, 0, dir, file, ext, 0] {
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
        if let Some((clone_id, ext_flags)) = extended {
            for value in [clone_id, ext_flags] {
                e.extend_from_slice(&value.to_le_bytes());
            }
        }
        let name_offset = (e.len() - name_ref) as u32;
        e[name_ref..name_ref + 4].copy_from_slice(&name_offset.to_le_bytes());
        e[name_ref + 4..name_ref + 8].copy_from_slice(&(name.len() as u32 + 1).to_le_bytes());
        e.extend_from_slice(name.as_bytes());
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
            let record = bulk_record(name, dir, flags, mount, links, None);
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
        assert!(entries.iter().all(|e| e.clone.is_none()), "no extended attributes, no sharing");
    }

    #[test]
    fn bulk_parser_reads_clone_attributes_after_file_attributes() {
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        for (name, ext) in [
            ("full", (99, EF_MAY_SHARE_BLOCKS | EF_SHARES_ALL_BLOCKS)),
            ("partial", (98, EF_MAY_SHARE_BLOCKS)),
            ("not-shared", (97, 0)),
        ] {
            let record = bulk_record(name, false, 0, 0, 1, Some(ext));
            assert!(parse_entry(&record, &mut entries, &mut names, &Progress::default()));
        }
        assert_eq!(&names[entries[1].name_end as usize..], b"not-shared", "name still found");
        assert_eq!((entries[0].size, entries[0].alloc), (12345, 16384));
        let info = |id, shares_all| Some(CloneInfo { key: (17, id), file_id: 123456, shares_all });
        assert_eq!(entries[0].clone, info(99, true));
        assert_eq!(entries[1].clone, info(98, false));
        assert_eq!(entries[2].clone, None);
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
        t.n_files = vec![0; n];
        t.unique = t.alloc.clone();
        let mut lists = vec![Vec::new(); n];
        for i in (1..n).rev() {
            let p = t.parents[i] as usize;
            t.alloc[p] += t.alloc[i];
            t.unique[p] += t.unique[i];
            t.logical[p] += t.logical[i];
            t.n_files[p] += if t.flags[i] & 1 != 0 { t.n_files[i] } else { 1 };
            t.complete[p] &= t.complete[i];
        }
        for i in 1..n {
            lists[t.parents[i] as usize].push(i as u32);
        }
        t.child_off = vec![0];
        for mut kids in lists {
            kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.unique[c as usize]));
            t.children.extend(kids);
            t.child_off.push(t.children.len() as u32);
        }
        t
    }

    #[test]
    fn finish_preserves_every_abi_column_and_child_order() {
        for (dirs, files) in [(0, 0), (3, 0), (1, 1024), (128, 4)] {
            let mut t = fixture(dirs, files);
            finish(&mut t, Vec::new());
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
                    finish(&mut t, Vec::new());
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
            let mut arena = Arena {
                tree,
                hardlinks: HashMap::new(),
                clones: Vec::new(),
                clone_keys: HashSet::new(),
            };
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
            finish(t, Vec::new());
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
        finish(&mut t, Vec::new());
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

    fn clonefile(src: &Path, dst: &Path) -> bool {
        let src = CString::new(src.as_os_str().as_encoded_bytes()).unwrap();
        let dst = CString::new(dst.as_os_str().as_encoded_bytes()).unwrap();
        unsafe { libc::clonefile(src.as_ptr(), dst.as_ptr(), 0) == 0 }
    }

    #[test]
    fn apfs_clones_count_once() {
        const COPY: u64 = 4 << 20;
        let root = std::env::temp_dir().join(format!("bz-test-clones-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["family/clones", "plain", "changed"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        let original = root.join("family/original");
        std::fs::write(&original, vec![7u8; COPY as usize]).unwrap();
        std::fs::write(root.join("plain/file"), vec![9u8; 100_000]).unwrap();
        if !clonefile(&original, &root.join("family/clones/a"))
            || !clonefile(&original, &root.join("family/clones/b"))
            || !clonefile(&original, &root.join("changed/c"))
        {
            let _ = std::fs::remove_dir_all(&root);
            eprintln!("skipped: temp dir is not on APFS ({})", std::io::Error::last_os_error());
            return;
        }
        // Rewriting part of a clone gives it a clone id of its own, and APFS
        // stops counting it as a clone, but it still shares the other blocks.
        {
            use std::os::unix::fs::FileExt;
            let f = std::fs::OpenOptions::new().write(true).open(root.join("changed/c")).unwrap();
            f.write_all_at(&[1u8; 65536], 0).unwrap();
            f.sync_all().unwrap();
        }

        let t = scan(&root, &Progress::default());
        let alone = scan(&root.join("family"), &Progress::default());
        let clones_alone = scan(&root.join("family/clones"), &Progress::default());
        let find = |n: &str| (0..t.len()).find(|&i| t.name(i) == n).unwrap();
        let (family, clones, plain, changed) = (find("family"), find("clones"), find("plain"), find("changed"));
        let reclaim = t.reclaimable(&[0]);
        let reclaim_parts = t.reclaimable(&[family as u32, changed as u32, plain as u32]);
        let reclaim_alone = alone.reclaimable(&[0]);
        let reclaim_clones_alone = clones_alone.reclaimable(&[0]);
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        let near = |a: u64, b: u64| a.abs_diff(b) <= 64 << 10;

        let plain_file = find("file");
        assert_eq!(t.unique[plain_file], t.alloc[plain_file], "a file that isn't cloned");
        assert!(t.alloc[plain_file] >= 100_000);
        assert_eq!(t.cloned(plain), 0);

        // The original and the two untouched clones count as one copy.
        assert!(near(t.alloc[family], 3 * COPY), "allocated size counts every clone: {}", t.alloc[family]);
        assert!(near(t.unique[family], COPY), "the folder holds one copy: {}", t.unique[family]);
        assert!(near(t.cloned(family), 2 * COPY), "two copies are cloned bytes: {}", t.cloned(family));
        // The original has the lowest file id, so it holds the shared bytes.
        assert!(near(t.unique[find("original")], COPY));
        assert_eq!(t.unique[clones], 0);
        assert_eq!((t.clone_groups.len(), t.clone_members.len()), (1, 3));
        // The changed clone shares blocks with a file it can't name: counted in full.
        assert_eq!(t.unique[changed], t.alloc[changed]);
        assert_eq!(t.partial_clones, [find("c") as u32]);

        // Only private blocks count as freed. Deleting the family frees
        // nothing: the changed clone outside it still holds the shared blocks.
        // Deleting the changed clone frees what was rewritten. Shared blocks
        // never count, even with everything deleted.
        assert_eq!(reclaim_parts[0], 0);
        assert!(near(reclaim_parts[1], 65536), "{}", reclaim_parts[1]);
        assert_eq!(reclaim_parts[2], t.unique[plain]);
        assert!(near(reclaim[0], t.unique[plain] + 65536), "{reclaim:?}");

        // Scanning only the family: it counts once and still frees nothing,
        // though every clone the scan sees is inside it.
        assert!(near(alone.unique[0], COPY), "{}", alone.unique[0]);
        assert!(near(alone.cloned(0), 2 * COPY));
        assert_eq!(reclaim_alone, [0]);
        // Scanning only the clones, without the original.
        assert!(near(clones_alone.unique[0], COPY), "{}", clones_alone.unique[0]);
        assert!(near(clones_alone.cloned(0), COPY));
        assert_eq!(reclaim_clones_alone, [0]);
    }

    #[test]
    fn a_hard_linked_clone_counts_once() {
        const COPY: u64 = 4 << 20;
        let root = std::env::temp_dir().join(format!("bz-test-linked-clone-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["a", "b"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        let original = root.join("a/original");
        std::fs::write(&original, vec![7u8; COPY as usize]).unwrap();
        if !clonefile(&original, &root.join("a/clone")) {
            let _ = std::fs::remove_dir_all(&root);
            eprintln!("skipped: temp dir is not on APFS ({})", std::io::Error::last_os_error());
            return;
        }
        // A second name for the clone: one inode, so one clone, not two.
        std::fs::hard_link(root.join("a/clone"), root.join("b/link")).unwrap();

        let t = scan(&root, &Progress::default());
        let reclaim = t.reclaimable(&[0]);
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        let near = |a: u64, b: u64| a.abs_diff(b) <= 64 << 10;
        let find = |n: &str| (0..t.len()).find(|&i| t.name(i) == n).unwrap();

        assert_eq!(t.n_files[0], 3, "every name is listed");
        assert!(near(t.alloc[0], 2 * COPY), "the link's bytes count once: {}", t.alloc[0]);
        assert_eq!(t.alloc[find("link")], 0, "a/clone sorts first and carries the bytes");
        assert!(near(t.unique[0], COPY), "the original and its clone are one copy: {}", t.unique[0]);
        assert_eq!(t.clone_members.len(), 2, "the zeroed link is not a clone member");
        assert_eq!(t.clone_groups.len(), 1);
        assert!(near(t.clone_groups[0].shared, COPY));
        assert_eq!(reclaim, [0], "shared blocks never count as freed");
    }

    #[test]
    fn clone_owner_does_not_depend_on_discovery_order() {
        let clone = [None, None, Some((77, 30)), Some((77, 10)), Some((77, 20)), Some((78, 40))];
        for order in [[2, 3, 4, 5], [5, 4, 2, 3], [3, 5, 4, 2]] {
            let mut t = Tree::with_root("/no-such-root");
            t.push("a", 0, 0, 0, true);
            t.push("1", 1, 8000, 8192, false);
            t.push("2", 1, 8000, 8192, false);
            t.push("3", 1, 8000, 8192, false);
            t.push("changed", 1, 8000, 8192, false);
            let clones = order
                .iter()
                .map(|&i| {
                    let (id, file_id) = clone[i].unwrap();
                    let shares_all = id == 77;
                    (CloneInfo { key: (1, id), file_id, shares_all }, i as u32)
                })
                .collect();
            finish(&mut t, clones);
            assert_eq!(t.unique[2..], [0, 8192, 0, 8192], "file id 10 holds the shared bytes");
            assert_eq!((t.alloc[0], t.unique[0], t.cloned(0)), (4 * 8192, 2 * 8192, 2 * 8192));
            assert_eq!(t.clone_members, [3, 4, 2]);
            assert_eq!(t.clone_groups, [CloneGroup { end: 3, shared: 8192 }]);
            assert_eq!(t.partial_clones, [5]);
            // Full clones free nothing, and with no files on disk the changed
            // file's private size is unknown, so nothing counts as freed.
            assert_eq!(t.reclaimable(&[1]), [0]);
            assert_eq!(t.reclaimable(&[3, 4]), [0, 0]);
            // A known private size is what deleting the changed file frees.
            let asked = std::cell::Cell::new(0);
            let private = |p: &Path| {
                asked.set(asked.get() + 1);
                assert!(p.ends_with("a/changed"));
                Some(3000)
            };
            assert_eq!(t.reclaimable_with(&[1], private), [3000]);
            assert_eq!(asked.get(), 1);
            assert_eq!(t.reclaimable_with(&[1], |_| None), [0]);
        }
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

        let h = bz_scan_start(path.as_ptr());
        let (mut f, mut d, mut b, mut done) = (0, 0, 0, 0);
        while done == 0 {
            std::thread::sleep(std::time::Duration::from_millis(1));
            bz_progress(h, &mut f, &mut d, &mut b, &mut done);
        }
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(bz_take_tree(h), 3);
        let s = |p: *const u32, n| unsafe { std::slice::from_raw_parts(p, n) };
        assert_eq!(s(bz_parents(h), 3), [NO_PARENT, 0, 1]);
        assert_eq!(s(bz_child_off(h), 4), [0, 1, 2, 2]);
        assert_eq!(s(bz_children(h), 2), [1, 2]);
        assert_eq!(s(bz_nfiles(h), 3), [1, 1, 0]);
        let off = s(bz_name_off(h), 4);
        let blob = unsafe { std::slice::from_raw_parts(bz_name_blob(h), off[3] as usize) };
        assert_eq!(&blob[off[1] as usize..], b"df");
        bz_free(h);
    }
}
