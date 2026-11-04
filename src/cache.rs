//! The last finished scan, saved so the next launch can show it at once
//! while a fresh scan runs.
//!
//! Only what can't be rebuilt is saved: each node's parent, name, flags,
//! completeness and, for files, sizes; plus the APFS clone lists. Folder
//! totals, file counts and the child lists are rebuilt on load, exactly as a
//! scan derives them.
//!
//! Layout, integers little-endian:
//!
//! ```text
//! magic "BZCACHE\0", format version u32, `SIZE_RULES` u32,
//! root path (u32 length + UTF-8), scan start (i64 ms since 1970),
//! volume UUID [u8; 16], node count u64, error count u64,
//! FNV-1a 64 of everything above,
//! then each column in a fixed order: raw length u64, chunk count u32,
//! per chunk (raw length u32, compressed length u32), then the chunks
//! (zstd frames with checksums).
//! ```
//!
//! Columns: parents as zigzag varints of `node - parent` (the root's parent
//! counts as -1); alloc, cloned bytes (alloc - unique) and logical as
//! varints (zero for folders);
//! flags and completeness as bytes; name lengths as varints and the names
//! end to end; clone members, clone groups (end, shared bytes) and partly
//! cloned files as varints.

use std::ffi::{c_void, CString};
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rayon::prelude::*;

use crate::{getattrlist, total_and_link, AttrList, CloneGroup, Tree, ATTR_BIT_MAP_COUNT, NO_PARENT, SIZE_RULES};

const MAGIC: &[u8; 8] = b"BZCACHE\0";
/// Bump whenever the layout or the meaning of a column changes. Changes to
/// how a scan counts sizes bump `crate::SIZE_RULES` instead.
pub const VERSION: u32 = 2;
/// zstd level: 3 makes files about 20% larger than 9 in under half the
/// time, and 6 saves only a few percent more (see BENCHMARKS.md).
pub const LEVEL: i32 = 3;
/// Columns are split into chunks this size so they compress and decompress
/// on every core.
const CHUNK: usize = 8 << 20;
const COLUMNS: usize = 11;
/// Most a file's columns may unpack to, as a multiple of the file's size.
const MAX_RATIO: u64 = 64;

/// What identifies the scan a cache belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    pub root: String,
    pub scanned_at: SystemTime,
    pub volume: [u8; 16],
}

/// Sizes of one encoded cache, for measurements.
#[derive(Clone, Debug, Default)]
pub struct Sizes {
    /// The columns varint-encoded, before compression.
    pub encoded: u64,
    /// The whole file.
    pub file: u64,
    /// Each column's (name, encoded bytes, compressed bytes).
    pub columns: Vec<(&'static str, u64, u64)>,
}

const COLUMN_NAMES: [&str; COLUMNS] = [
    "parents", "alloc", "cloned", "logical", "flags", "complete", "name lengths", "names",
    "clone members", "clone groups", "partial clones",
];

fn invalid(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, what.to_string())
}

// ---- Volume identity ----

const ATTR_VOL_INFO: u32 = 0x8000_0000;
const ATTR_VOL_UUID: u32 = 0x0004_0000;

/// The UUID of the volume `path` is on, so a cache from another disk mounted
/// at the same path is never shown. Volumes without one fall back to the
/// file system ID, which can change across restarts (a stale cache is then
/// only ignored).
pub fn volume_id(path: &Path) -> Option<[u8; 16]> {
    let c = CString::new(path.as_os_str().as_encoded_bytes()).ok()?;
    let mut fs: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(c.as_ptr(), &mut fs) } != 0 {
        return None;
    }
    let mut attrs = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: 0,
        volattr: ATTR_VOL_INFO | ATTR_VOL_UUID,
        dirattr: 0,
        fileattr: 0,
        forkattr: 0,
    };
    // Volume attributes are only returned for the volume's root.
    let mount = fs.f_mntonname.as_ptr();
    let mut buf = [0u8; 4 + 16];
    let status = unsafe { getattrlist(mount, &mut attrs, buf.as_mut_ptr() as *mut c_void, buf.len(), 0) };
    let mut id = [0u8; 16];
    if status == 0 && buf[4..].iter().any(|&b| b != 0) {
        id.copy_from_slice(&buf[4..]);
    } else {
        // fsid_t is two int32s, whose field libc keeps private.
        let fsid: [u8; 8] = unsafe { std::mem::transmute(fs.f_fsid) };
        id[..8].copy_from_slice(&fsid);
    }
    Some(id)
}

// ---- Varints ----

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push(v as u8 | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

fn unzigzag(v: u64) -> i64 {
    (v >> 1) as i64 ^ -((v & 1) as i64)
}

/// Reads varints from one column, which must hold exactly as many as asked.
struct Varints<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Varints<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Varints { bytes, at: 0 }
    }
    fn next(&mut self) -> io::Result<u64> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let &b = self.bytes.get(self.at).ok_or_else(|| invalid("column ends early"))?;
            self.at += 1;
            if shift == 63 && b > 1 {
                return Err(invalid("varint overflows"));
            }
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
        }
        Err(invalid("varint overflows"))
    }
    #[cfg(test)]
    fn read<T>(&mut self, count: usize, f: impl Fn(u64) -> io::Result<T>) -> io::Result<Vec<T>> {
        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            out.push(f(self.next()?)?);
        }
        Ok(out)
    }
    #[cfg(test)]
    fn finish(&self) -> io::Result<()> {
        if self.at == self.bytes.len() {
            Ok(())
        } else {
            Err(invalid("column has extra bytes"))
        }
    }
}

fn varints(values: impl Iterator<Item = u64>, capacity: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(capacity);
    for v in values {
        put_varint(&mut out, v);
    }
    out
}

fn u32_value(v: u64) -> io::Result<u32> {
    u32::try_from(v).map_err(|_| invalid("value out of range"))
}

// ---- Encoding ----

/// One column of `t`, before compression.
fn column(t: &Tree, c: usize) -> Vec<u8> {
    let n = t.len();
    // Folder totals are rebuilt on load, so folders store zero.
    let own = |v: &dyn Fn(usize) -> u64| varints((0..n).map(|i| if t.is_dir(i) { 0 } else { v(i) }), n * 3);
    match c {
        0 => varints(
            (0..n).map(|i| {
                let p = if t.parents[i] == NO_PARENT { -1 } else { t.parents[i] as i64 };
                zigzag(i as i64 - p)
            }),
            n * 2,
        ),
        1 => own(&|i| t.alloc[i]),
        // Almost always zero: most files share no blocks.
        2 => own(&|i| t.cloned(i)),
        3 => own(&|i| t.logical[i]),
        4 => t.flags.clone(),
        5 => t.complete.iter().map(|&c| c as u8).collect(),
        6 => varints(t.name_off.windows(2).map(|w| (w[1] - w[0]) as u64), n),
        7 => t.name_blob[..t.name_off[n] as usize].to_vec(),
        8 => varints(t.clone_members.iter().map(|&i| i as u64), t.clone_members.len()),
        9 => varints(
            t.clone_groups.iter().flat_map(|g| [g.end as u64, g.shared]),
            t.clone_groups.len() * 4,
        ),
        _ => varints(t.partial_clones.iter().map(|&i| i as u64), t.partial_clones.len()),
    }
}

fn header_bytes(h: &Header, nodes: u64, errors: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(64 + h.root.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&SIZE_RULES.to_le_bytes());
    out.extend_from_slice(&(h.root.len() as u32).to_le_bytes());
    out.extend_from_slice(h.root.as_bytes());
    let ms = match h.scanned_at.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_millis() as i64,
        Err(e) => -(e.duration().as_millis() as i64),
    };
    out.extend_from_slice(&ms.to_le_bytes());
    out.extend_from_slice(&h.volume);
    out.extend_from_slice(&nodes.to_le_bytes());
    out.extend_from_slice(&errors.to_le_bytes());
    let sum = fnv1a(&out);
    out.extend_from_slice(&sum.to_le_bytes());
    out
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, &b| (h ^ b as u64).wrapping_mul(0x0100_0000_01b3))
}

/// The cache file's bytes for `t`, compressed at `level`.
pub fn encode(t: &Tree, h: &Header, level: i32) -> io::Result<(Vec<u8>, Sizes)> {
    let raw: Vec<Vec<u8>> = (0..COLUMNS).into_par_iter().map(|c| column(t, c)).collect();
    let chunks: Vec<(usize, &[u8])> = raw
        .iter()
        .enumerate()
        .flat_map(|(c, col)| col.chunks(CHUNK).map(move |chunk| (c, chunk)))
        .collect();
    let packed: Vec<io::Result<Vec<u8>>> = chunks
        .par_iter()
        .map(|&(_, chunk)| {
            let mut z = zstd::bulk::Compressor::new(level)?;
            z.set_parameter(zstd::zstd_safe::CParameter::ChecksumFlag(true))?;
            z.compress(chunk)
        })
        .collect();
    let mut out = header_bytes(h, t.len() as u64, t.errors);
    let mut columns = Vec::with_capacity(COLUMNS);
    let mut packed = packed.into_iter();
    let mut chunks = chunks.iter().peekable();
    for (c, col) in raw.iter().enumerate() {
        let mut frames = Vec::new();
        while let Some((_, chunk)) = chunks.next_if(|(owner, _)| *owner == c) {
            frames.push((chunk.len(), packed.next().unwrap()?));
        }
        out.extend_from_slice(&(col.len() as u64).to_le_bytes());
        out.extend_from_slice(&(frames.len() as u32).to_le_bytes());
        for (len, frame) in &frames {
            out.extend_from_slice(&(*len as u32).to_le_bytes());
            out.extend_from_slice(&(frame.len() as u32).to_le_bytes());
        }
        for (_, frame) in &frames {
            out.extend_from_slice(frame);
        }
        let packed_len = frames.iter().map(|(_, f)| f.len() as u64).sum();
        columns.push((COLUMN_NAMES[c], col.len() as u64, packed_len));
    }
    let sizes = Sizes {
        encoded: raw.iter().map(|c| c.len() as u64).sum(),
        file: out.len() as u64,
        columns,
    };
    Ok((out, sizes))
}

/// Write the cache for `t` to `dest`: to a temporary file next to it first,
/// renamed into place, so a reader never sees half a file.
pub fn save(t: &Tree, root: &Path, scanned_at: SystemTime, dest: &Path) -> io::Result<Sizes> {
    let root = root.to_str().ok_or_else(|| invalid("root path is not UTF-8"))?;
    let volume = volume_id(Path::new(root)).ok_or_else(|| invalid("can't identify the volume"))?;
    let h = Header { root: root.to_string(), scanned_at, volume };
    let (bytes, sizes) = encode(t, &h, LEVEL)?;
    if let Some(dir) = dest.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // Each save gets its own temporary file, so two saves of the same folder
    // never write into one; the last rename wins.
    static SAVES: AtomicU64 = AtomicU64::new(0);
    let mut tmp = dest.as_os_str().to_owned();
    tmp.push(format!(".tmp-{}-{}", std::process::id(), SAVES.fetch_add(1, Ordering::Relaxed)));
    let mut created = false;
    let result = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .and_then(|mut f| {
            created = true;
            f.write_all(&bytes)?;
            f.sync_all()
        })
        .and_then(|_| std::fs::rename(&tmp, dest));
    // A file that create_new refused belongs to someone else.
    if result.is_err() && created {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map(|_| sizes)
}

// ---- Decoding ----

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> io::Result<&'a [u8]> {
        let end = self.at.checked_add(n).filter(|&e| e <= self.bytes.len());
        let end = end.ok_or_else(|| invalid("file ends early"))?;
        let out = &self.bytes[self.at..end];
        self.at = end;
        Ok(out)
    }
    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
}

/// Read the header. Fails when the file is from another format version.
fn read_header(r: &mut Reader) -> io::Result<(Header, u64, u64)> {
    if r.take(8)? != MAGIC {
        return Err(invalid("not a scan cache"));
    }
    if r.u32()? != VERSION {
        return Err(invalid("cache is from another version"));
    }
    if r.u32()? != SIZE_RULES {
        return Err(invalid("cache counted sizes another way"));
    }
    let root_len = r.u32()? as usize;
    let root = std::str::from_utf8(r.take(root_len)?).map_err(|_| invalid("root path is not UTF-8"))?;
    let ms = r.u64()? as i64;
    let volume: [u8; 16] = r.take(16)?.try_into().unwrap();
    let nodes = r.u64()?;
    let errors = r.u64()?;
    let end = r.at;
    if r.u64()? != fnv1a(&r.bytes[..end]) {
        return Err(invalid("header checksum mismatch"));
    }
    let offset = Duration::from_millis(ms.unsigned_abs());
    let scanned_at = if ms >= 0 { UNIX_EPOCH + offset } else { UNIX_EPOCH - offset };
    Ok((Header { root: root.to_string(), scanned_at, volume }, nodes, errors))
}

/// The header of a cache file, without reading its columns.
pub fn peek(bytes: &[u8]) -> io::Result<Header> {
    read_header(&mut Reader { bytes, at: 0 }).map(|(h, ..)| h)
}

/// One column's chunk table: (raw length, compressed frame) per chunk.
fn chunk_table<'a>(r: &mut Reader<'a>, max_raw: u64) -> io::Result<(usize, Vec<(usize, &'a [u8])>)> {
    let raw = r.u64()?;
    if raw > max_raw {
        return Err(invalid("column is too long"));
    }
    let count = r.u32()? as usize;
    if count != (raw as usize).div_ceil(CHUNK) {
        return Err(invalid("wrong chunk count"));
    }
    let mut lens = Vec::with_capacity(count);
    for _ in 0..count {
        lens.push((r.u32()? as usize, r.u32()? as usize));
    }
    let mut chunks = Vec::with_capacity(count);
    let mut total = 0usize;
    for (raw_len, packed_len) in lens {
        if raw_len > CHUNK {
            return Err(invalid("chunk is too long"));
        }
        total += raw_len;
        let frame = r.take(packed_len)?;
        // zstd records each frame's size; it must agree with the table.
        if !matches!(zstd::zstd_safe::get_frame_content_size(frame), Ok(Some(s)) if s == raw_len as u64) {
            return Err(invalid("chunk length doesn't match its frame"));
        }
        chunks.push((raw_len, frame));
    }
    if total as u64 != raw {
        return Err(invalid("chunk lengths don't add up"));
    }
    Ok((raw as usize, chunks))
}

/// Parse and check a cache file's bytes against the root and volume being
/// scanned, then rebuild the tree. Any damage is an error, never a panic.
pub fn decode(bytes: &[u8], root: &str, volume: [u8; 16]) -> io::Result<(Tree, SystemTime)> {
    let started = std::time::Instant::now();
    let mut r = Reader { bytes, at: 0 };
    let (h, nodes, errors) = read_header(&mut r)?;
    if h.root != root {
        return Err(invalid("cache is for another folder"));
    }
    if h.volume != volume {
        return Err(invalid("cache is for another volume"));
    }
    if nodes == 0 || nodes >= NO_PARENT as u64 {
        return Err(invalid("bad node count"));
    }
    let n = nodes as usize;
    let varint_max = 10 * nodes;
    let limits = [
        varint_max, varint_max, varint_max, varint_max, nodes, nodes, varint_max,
        u32::MAX as u64, varint_max, 2 * varint_max, varint_max,
    ];
    let mut tables = Vec::with_capacity(COLUMNS);
    for max in limits {
        tables.push(chunk_table(&mut r, max)?);
    }
    if r.at != bytes.len() {
        return Err(invalid("file has extra bytes"));
    }
    // Memory is allocated from the declared counts, so tie them to the
    // file's size: a small damaged file must not ask for gigabytes. Measured
    // scans took 5 to 13 bytes per node on disk and their columns compressed
    // 3 to 6 times, so these limits leave a wide margin.
    if nodes > bytes.len() as u64 {
        return Err(invalid("too many nodes for the file size"));
    }
    let raw_total: u64 = tables.iter().map(|(raw, _)| *raw as u64).sum();
    if raw_total > MAX_RATIO * bytes.len() as u64 {
        return Err(invalid("columns too large for the file size"));
    }

    // Columns with one varint per node stream through a small buffer as they
    // decode (below): unpacked whole, they would add hundreds of megabytes
    // on a whole-disk scan. Every other column unpacks in place, its chunks
    // in parallel.
    let streamed = |c: usize| matches!(c, 0 | 1 | 2 | 3 | 6);
    let mut cols: Vec<Vec<u8>> =
        tables.iter().enumerate().map(|(c, (raw, _))| vec![0u8; if streamed(c) { 0 } else { *raw }]).collect();
    let mut jobs = Vec::new();
    for (c, (col, (_, chunks))) in cols.iter_mut().zip(&tables).enumerate() {
        if streamed(c) {
            continue;
        }
        let mut rest = col.as_mut_slice();
        for &(len, frame) in chunks {
            let (dst, tail) = rest.split_at_mut(len);
            rest = tail;
            jobs.push((dst, frame));
        }
    }
    jobs.into_par_iter().try_for_each(|(dst, frame)| {
        let len = dst.len();
        match zstd::bulk::decompress_to_buffer(frame, dst) {
            Ok(got) if got == len => Ok(()),
            _ => Err(invalid("damaged column")),
        }
    })?;
    let unpacked = std::time::Instant::now();

    let mut t = Tree { errors, ..Default::default() };
    let parent_of = |i: usize, v: u64| match (i, (i as i64).checked_sub(unzigzag(v))) {
        (0, Some(-1)) => Ok(NO_PARENT),
        (1.., Some(p @ 0..)) if (p as usize) < i => Ok(p as u32),
        _ => Err(invalid("bad parent")),
    };
    let names_len = cols[7].len() as u64;
    // One value per node in each of these, decoded straight into the tree's
    // own columns, one column per core. Whole-disk trees have tens of
    // millions of nodes, so a u64 staging copy of each would cost gigabytes.
    let ((parents, name_off), ((alloc, unique), logical)) = rayon::join(
        || rayon::join(|| per_node(&tables[0].1, n, parent_of), || name_offsets(&tables[6].1, n, names_len)),
        || {
            rayon::join(
                || rayon::join(|| per_node(&tables[1].1, n, |_, v| Ok(v)), || per_node(&tables[2].1, n, |_, v| Ok(v))),
                || per_node(&tables[3].1, n, |_, v| Ok(v)),
            )
        },
    );
    (t.parents, t.name_off, t.alloc, t.unique, t.logical) = (parents?, name_off?, alloc?, unique?, logical?);
    // The file stores cloned bytes; the tree keeps unique = alloc - cloned.
    // The UI subtracts unique from allocated bytes, so it must not exceed it.
    t.unique.par_iter_mut().zip(&t.alloc).try_for_each(|(u, &a)| {
        *u = a.checked_sub(*u).ok_or_else(|| invalid("more cloned bytes than allocated"))?;
        Ok::<_, io::Error>(())
    })?;
    if cols[4].len() != n || cols[5].len() != n {
        return Err(invalid("flag column has the wrong length"));
    }
    t.flags = std::mem::take(&mut cols[4]);
    t.complete = cols[5].iter().map(|&c| c != 0).collect();
    cols[5] = Vec::new();
    t.name_blob = std::mem::take(&mut cols[7]);
    // Paths are built by joining names, so each must be one real name.
    if t.name_bytes(0) != h.root.as_bytes() {
        return Err(invalid("root name doesn't match the folder"));
    }
    (1..n).into_par_iter().try_for_each(|i| {
        let name = t.name_bytes(i);
        let bad = name.is_empty() || name == b"." || name == b".." || name.contains(&b'/');
        if bad || std::str::from_utf8(name).is_err() {
            return Err(invalid("bad name"));
        }
        Ok(())
    })?;

    let node = |v: u64| match u32_value(v) {
        Ok(i) if (i as usize) < n => Ok(i),
        _ => Err(invalid("node out of range")),
    };
    let mut members = Varints::new(&cols[8]);
    let mut m = Vec::new();
    while members.at < cols[8].len() {
        m.push(node(members.next()?)?);
    }
    t.clone_members = m;
    let mut groups = Varints::new(&cols[9]);
    let mut previous = 0u32;
    while groups.at < cols[9].len() {
        let end = u32_value(groups.next()?)?;
        let shared = groups.next()?;
        if end <= previous || end as usize > t.clone_members.len() {
            return Err(invalid("bad clone group"));
        }
        previous = end;
        t.clone_groups.push(CloneGroup { end, shared });
    }
    if previous as usize != t.clone_members.len() {
        return Err(invalid("clone groups don't cover their members"));
    }
    let mut partial = Varints::new(&cols[10]);
    while partial.at < cols[10].len() {
        t.partial_clones.push(node(partial.next()?)?);
    }

    check_shape(&t)?;
    let parsed = std::time::Instant::now();
    total_and_link(&mut t);
    if std::env::var_os("BZ_TIMING").is_some() {
        eprintln!(
            "[bz] cache decompress {:.1}ms  parse {:.1}ms  rebuild {:.1}ms",
            (unpacked - started).as_secs_f64() * 1e3,
            (parsed - unpacked).as_secs_f64() * 1e3,
            parsed.elapsed().as_secs_f64() * 1e3
        );
    }
    Ok((t, h.scanned_at))
}

/// A column's varints, unpacked one chunk at a time into a buffer that
/// holds that chunk plus the few bytes of a varint split across chunks.
struct Stream<'a> {
    chunks: &'a [(usize, &'a [u8])],
    next_chunk: usize,
    buf: Vec<u8>,
    at: usize,
}

impl<'a> Stream<'a> {
    fn new(chunks: &'a [(usize, &'a [u8])]) -> Self {
        Stream { chunks, next_chunk: 0, buf: Vec::new(), at: 0 }
    }
    fn next(&mut self) -> io::Result<u64> {
        // A varint is at most 10 bytes.
        while self.buf.len() - self.at < 10 && self.next_chunk < self.chunks.len() {
            self.buf.drain(..self.at);
            self.at = 0;
            let (len, frame) = self.chunks[self.next_chunk];
            self.next_chunk += 1;
            let start = self.buf.len();
            self.buf.resize(start + len, 0);
            match zstd::bulk::decompress_to_buffer(frame, &mut self.buf[start..]) {
                Ok(got) if got == len => {}
                _ => return Err(invalid("damaged column")),
            }
        }
        let mut v = Varints { bytes: &self.buf, at: self.at };
        let value = v.next()?;
        self.at = v.at;
        Ok(value)
    }
    fn finish(&self) -> io::Result<()> {
        if self.next_chunk == self.chunks.len() && self.at == self.buf.len() {
            Ok(())
        } else {
            Err(invalid("column has extra bytes"))
        }
    }
}

/// Exactly `n` varints from a column, each turned into a value by `f(index, v)`.
fn per_node<T>(
    col: &[(usize, &[u8])],
    n: usize,
    f: impl Fn(usize, u64) -> io::Result<T>,
) -> io::Result<Vec<T>> {
    let mut v = Stream::new(col);
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        out.push(f(i, v.next()?)?);
    }
    v.finish()?;
    Ok(out)
}

/// Name offsets from `n` name lengths, which must add up to `names_len`.
fn name_offsets(col: &[(usize, &[u8])], n: usize, names_len: u64) -> io::Result<Vec<u32>> {
    let mut v = Stream::new(col);
    let mut out = Vec::with_capacity(n + 1);
    out.push(0);
    let mut end = 0u64;
    for _ in 0..n {
        end = end.saturating_add(v.next()?);
        if end > names_len {
            return Err(invalid("names run past the end"));
        }
        out.push(end as u32);
    }
    v.finish()?;
    if end != names_len {
        return Err(invalid("names don't add up"));
    }
    Ok(out)
}

/// What rebuilding totals and child lists relies on, checked so a damaged
/// file can't make them overflow or index out of bounds: the root is a
/// folder, every parent is a folder, each folder's children are one run,
/// and folders store no sizes of their own.
fn check_shape(t: &Tree) -> io::Result<()> {
    let n = t.len();
    if !t.is_dir(0) {
        return Err(invalid("root is not a folder"));
    }
    let mut has_run = vec![false; n];
    let mut previous = NO_PARENT;
    let (mut alloc, mut logical) = (0u64, 0u64);
    for i in 0..n {
        if t.is_dir(i) {
            if t.alloc[i] != 0 || t.unique[i] != 0 || t.logical[i] != 0 {
                return Err(invalid("folder has sizes of its own"));
            }
        }
        alloc = alloc.checked_add(t.alloc[i]).ok_or_else(|| invalid("sizes overflow"))?;
        logical = logical.checked_add(t.logical[i]).ok_or_else(|| invalid("sizes overflow"))?;
        let p = t.parents[i];
        if i == 0 || p == previous {
            continue;
        }
        if !t.is_dir(p as usize) || std::mem::replace(&mut has_run[p as usize], true) {
            return Err(invalid("children are not grouped under one folder"));
        }
        previous = p;
    }
    Ok(())
}

/// Load the cache at `src` if it belongs to a scan of `root` on the volume
/// `root` is on now.
pub fn load(src: &Path, root: &Path) -> io::Result<(Tree, SystemTime)> {
    let root = root.to_str().ok_or_else(|| invalid("root path is not UTF-8"))?;
    let volume = volume_id(Path::new(root)).ok_or_else(|| invalid("can't identify the volume"))?;
    let file = Mapped::open(src)?;
    decode(file.bytes(), root, volume)
}

/// A file mapped read-only. Unlike a copy on the heap, its pages are backed
/// by the file, so under memory pressure the system drops them instead of
/// swapping.
struct Mapped {
    ptr: *mut c_void,
    len: usize,
}

impl Mapped {
    fn open(path: &Path) -> io::Result<Mapped> {
        use std::os::fd::AsRawFd;
        let file = std::fs::File::open(path)?;
        let len = file.metadata()?.len() as usize;
        if len == 0 {
            return Err(invalid("cache file is empty"));
        }
        // SAFETY: a fresh read-only private mapping of a file we opened; it
        // stays valid after the descriptor closes. Saves replace the file
        // by rename, so the mapped file itself is never rewritten.
        let ptr = unsafe { libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ, libc::MAP_PRIVATE, file.as_raw_fd(), 0) };
        if ptr == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        Ok(Mapped { ptr, len })
    }
    fn bytes(&self) -> &[u8] {
        // SAFETY: the mapping is `len` readable bytes until drop.
        unsafe { std::slice::from_raw_parts(self.ptr as *const u8, self.len) }
    }
}

impl Drop for Mapped {
    fn drop(&mut self) {
        // SAFETY: unmaps exactly the region mmap returned.
        unsafe { libc::munmap(self.ptr, self.len) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{scan, Progress};

    fn sample() -> (std::path::PathBuf, Tree) {
        let root = std::env::temp_dir().join(format!("bz-cache-test-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("a/b/empty")).unwrap();
        std::fs::create_dir_all(root.join("wide")).unwrap();
        std::fs::write(root.join("a/b/document-é-日本語"), vec![3u8; 70_000]).unwrap();
        std::fs::write(root.join("a/small"), b"hi").unwrap();
        for i in 0..300 {
            std::fs::write(root.join(format!("wide/f{i}")), vec![1u8; i * 37]).unwrap();
        }
        // A family of clones, when the temp dir is on APFS.
        let src = CString::new(root.join("a/small").as_os_str().as_encoded_bytes()).unwrap();
        for name in ["clone-1", "clone-2"] {
            let dst = CString::new(root.join(name).as_os_str().as_encoded_bytes()).unwrap();
            unsafe { libc::clonefile(src.as_ptr(), dst.as_ptr(), 0) };
        }
        let t = scan(&root, &Progress::default());
        (root, t)
    }

    #[test]
    fn round_trip_keeps_every_column() {
        let (root, t) = sample();
        let file = root.with_extension("bzcache");
        let at = UNIX_EPOCH + Duration::from_millis(1_790_000_000_123);
        save(&t, &root, at, &file).unwrap();
        let (back, scanned_at) = load(&file, &root).unwrap();
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_file(&file);
        assert_eq!(scanned_at, at);
        assert!(t.len() > 300);
        assert_eq!(back.parents, t.parents);
        assert_eq!(back.alloc, t.alloc);
        assert_eq!(back.unique, t.unique);
        assert_eq!(back.logical, t.logical);
        assert_eq!(back.n_files, t.n_files);
        assert_eq!(back.flags, t.flags);
        assert_eq!(back.complete, t.complete);
        assert_eq!(back.child_off, t.child_off);
        assert_eq!(back.children, t.children);
        assert_eq!(back.name_off, t.name_off);
        assert_eq!(back.name_blob, t.name_blob);
        assert_eq!(back.clone_members, t.clone_members);
        assert_eq!(back.clone_groups, t.clone_groups);
        assert_eq!(back.partial_clones, t.partial_clones);
        assert_eq!(back.errors, t.errors);
        assert_eq!(back, t);
    }

    #[test]
    fn round_trip_handles_hand_built_clone_lists_and_errors() {
        let mut t = Tree::with_root("/no-such-root");
        t.push("d", 0, 0, 0, true);
        for k in 0..4 {
            t.push(&format!("f{k}"), 1, 9000, 8192, false);
        }
        t.unique[3] = 0;
        t.complete[2] = false;
        t.clone_members = vec![2, 3, 4];
        t.clone_groups = vec![CloneGroup { end: 2, shared: 8192 }, CloneGroup { end: 3, shared: 1 }];
        t.partial_clones = vec![5];
        t.errors = 7;
        total_and_link(&mut t);
        let h = Header { root: "/no-such-root".into(), scanned_at: UNIX_EPOCH, volume: [9; 16] };
        let (bytes, _) = encode(&t, &h, LEVEL).unwrap();
        let (back, _) = decode(&bytes, "/no-such-root", [9; 16]).unwrap();
        assert_eq!(back, t);
    }

    fn encoded() -> (Vec<u8>, Header) {
        let mut t = Tree::with_root("/r");
        t.push("x", 0, 5, 4096, false);
        total_and_link(&mut t);
        let scanned_at = UNIX_EPOCH + Duration::from_millis(1_790_000_000_000);
        let h = Header { root: "/r".into(), scanned_at, volume: [1; 16] };
        (encode(&t, &h, LEVEL).unwrap().0, h)
    }

    #[test]
    fn another_version_root_or_volume_is_ignored() {
        let (bytes, h) = encoded();
        assert!(decode(&bytes, "/r", h.volume).is_ok());
        assert_eq!(peek(&bytes).unwrap(), h);
        let mut newer = bytes.clone();
        newer[8..12].copy_from_slice(&(VERSION + 1).to_le_bytes());
        let err = decode(&newer, "/r", h.volume).unwrap_err();
        assert!(err.to_string().contains("version"), "{err}");
        let mut recounted = bytes.clone();
        recounted[12..16].copy_from_slice(&(SIZE_RULES + 1).to_le_bytes());
        let err = decode(&recounted, "/r", h.volume).unwrap_err();
        assert!(err.to_string().contains("sizes another way"), "{err}");
        assert!(decode(&bytes, "/other", h.volume).is_err());
        assert!(decode(&bytes, "/r", [2; 16]).is_err());
    }

    /// A well-formed file whose columns are all zeros of the given lengths.
    fn zeros_file(nodes: u64, raws: [u64; COLUMNS]) -> Vec<u8> {
        let h = Header { root: "/r".into(), scanned_at: UNIX_EPOCH, volume: [1; 16] };
        let zeros = vec![0u8; CHUNK];
        let mut out = header_bytes(&h, nodes, 0);
        for raw in raws {
            let raw = raw as usize;
            let frames: Vec<Vec<u8>> = (0..raw.div_ceil(CHUNK))
                .map(|k| zstd::bulk::compress(&zeros[..CHUNK.min(raw - k * CHUNK)], LEVEL).unwrap())
                .collect();
            out.extend_from_slice(&(raw as u64).to_le_bytes());
            out.extend_from_slice(&(frames.len() as u32).to_le_bytes());
            for (k, f) in frames.iter().enumerate() {
                out.extend_from_slice(&(CHUNK.min(raw - k * CHUNK) as u32).to_le_bytes());
                out.extend_from_slice(&(f.len() as u32).to_le_bytes());
            }
            for f in &frames {
                out.extend_from_slice(f);
            }
        }
        out
    }

    #[test]
    fn a_small_file_cannot_ask_for_much_memory() {
        // 50M nodes of one byte per column: 350 MB of columns.
        let n = 50_000_000;
        let many_nodes = zeros_file(n, [n, n, n, n, n, n, n, 0, 0, 0, 0]);
        assert!(many_nodes.len() < 1 << 20, "{}", many_nodes.len());
        let err = decode(&many_nodes, "/r", [1; 16]).unwrap_err();
        assert!(err.to_string().contains("too many nodes"), "{err}");
        // Few nodes, but 1 GB of names.
        let long_names = zeros_file(1000, [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1 << 30, 0, 0, 0]);
        assert!(long_names.len() < 1 << 20, "{}", long_names.len());
        let err = decode(&long_names, "/r", [1; 16]).unwrap_err();
        assert!(err.to_string().contains("columns too large"), "{err}");
    }

    #[test]
    fn names_that_would_make_bad_paths_are_rejected() {
        let build = |root: &str, name: &[u8]| {
            let mut t = Tree::with_root(root);
            t.push("d", 0, 0, 0, true);
            t.push("ok", 1, 5, 4096, false);
            let at = t.name_off[2] as usize;
            t.name_blob.splice(at..at + 2, name.iter().copied());
            t.name_off[3] = (at + name.len()) as u32;
            total_and_link(&mut t);
            let h = Header { root: "/r".into(), scanned_at: UNIX_EPOCH, volume: [1; 16] };
            decode(&encode(&t, &h, LEVEL).unwrap().0, "/r", [1; 16])
        };
        assert!(build("/r", b"fine name").is_ok());
        let err = build("/elsewhere", b"ok").unwrap_err();
        assert!(err.to_string().contains("root name"), "{err}");
        for name in [&b""[..], b".", b"..", b"a/b", b"/", b"\xff\xfe"] {
            let err = build("/r", name).unwrap_err();
            assert!(err.to_string().contains("bad name"), "{name:?}: {err}");
        }
    }

    #[test]
    fn truncated_or_damaged_files_are_errors_not_panics() {
        let (root_dir, t) = sample();
        // A file cut short on disk, as a crash mid-write would leave it
        // without the rename.
        let file = root_dir.with_extension("bzcache");
        save(&t, &root_dir, SystemTime::now(), &file).unwrap();
        let whole = std::fs::read(&file).unwrap();
        std::fs::write(&file, &whole[..whole.len() / 2]).unwrap();
        let cut = load(&file, &root_dir);
        let _ = std::fs::remove_file(&file);
        let _ = std::fs::remove_dir_all(&root_dir);
        assert!(cut.is_err());

        let root = root_dir.to_str().unwrap();
        let h = Header { root: root.into(), scanned_at: SystemTime::now(), volume: [4; 16] };
        let (bytes, _) = encode(&t, &h, LEVEL).unwrap();
        assert!(decode(&bytes, root, h.volume).is_ok());
        for len in (0..bytes.len()).step_by(7).chain([bytes.len() - 1]) {
            assert!(decode(&bytes[..len], root, h.volume).is_err(), "truncated to {len}");
        }
        let mut longer = bytes.clone();
        longer.push(0);
        assert!(decode(&longer, root, h.volume).is_err());
        // Flip one bit at a time: the header checksum and zstd's frame
        // checksums catch it, and the shape checks back them up.
        for at in (0..bytes.len()).step_by(3) {
            let mut bad = bytes.clone();
            bad[at] ^= 0x10;
            if let Ok((t2, _)) = decode(&bad, root, h.volume) {
                assert_eq!(t2.len(), t.len(), "a change that decodes must be harmless");
            }
        }
    }

    #[test]
    fn varints_round_trip_at_the_edges() {
        let values = [0, 1, 127, 128, 16_383, 16_384, u32::MAX as u64, u64::MAX];
        let bytes = varints(values.iter().copied(), 0);
        let mut v = Varints::new(&bytes);
        assert_eq!(v.read(values.len(), Ok).unwrap(), values);
        v.finish().unwrap();
        for d in [0i64, 1, -1, i64::MAX, i64::MIN] {
            assert_eq!(unzigzag(zigzag(d)), d);
        }
        assert!(Varints::new(&[0xff; 11]).next().is_err());
    }

    #[test]
    fn streamed_varints_cross_chunk_boundaries() {
        let values: Vec<u64> = (0..200).map(|i| if i % 3 == 0 { u64::MAX >> (i % 64) } else { i }).collect();
        let bytes = varints(values.iter().copied(), 0);
        // 7-byte chunks split most of the long varints.
        let frames: Vec<(usize, Vec<u8>)> =
            bytes.chunks(7).map(|c| (c.len(), zstd::bulk::compress(c, LEVEL).unwrap())).collect();
        let chunks: Vec<(usize, &[u8])> = frames.iter().map(|(len, f)| (*len, f.as_slice())).collect();
        assert_eq!(per_node(&chunks, values.len(), |_, v| Ok(v)).unwrap(), values);
        // One value too few leaves bytes over; one too many runs out.
        assert!(per_node(&chunks, values.len() - 1, |_, v| Ok(v)).is_err());
        assert!(per_node(&chunks, values.len() + 1, |_, v| Ok(v)).is_err());
        // A frame that unpacks to the wrong length is damage.
        let mut short = chunks.clone();
        short[3].0 += 1;
        assert!(per_node(&short, values.len(), |_, v| Ok(v)).is_err());
    }
}
