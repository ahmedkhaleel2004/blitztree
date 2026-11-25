//! The file-type breakdown: allocated bytes and file counts per extension
//! under one folder (WizTree's Extensions tab). The UI colors each row with
//! the same table the treemap uses (app/Treemap.swift, `TypeColor`), so the
//! extension rule here must match the one the treemap reads names with.
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

use rayon::prelude::*;

use crate::Tree;

/// Folders with at least this many files below them are split across threads.
const PARALLEL_FILES: u32 = 32_768;

/// One row per extension, flat like the tree: row `i`'s extension is
/// `ext_blob[ext_off[i]..ext_off[i + 1]]`, empty for files without one.
/// Sorted by allocated bytes, largest first, then by file count and name.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Breakdown {
    pub ext_off: Vec<u32>,
    pub ext_blob: Vec<u8>,
    pub alloc: Vec<u64>,
    pub files: Vec<u64>,
}

impl Breakdown {
    pub fn len(&self) -> usize {
        self.alloc.len()
    }
    pub fn is_empty(&self) -> bool {
        self.alloc.is_empty()
    }
    pub fn ext(&self, i: usize) -> &[u8] {
        &self.ext_blob[self.ext_off[i] as usize..self.ext_off[i + 1] as usize]
    }
}

/// A file name's extension: the bytes after its last dot, ASCII-lowercased
/// by the caller. None for names without a dot, dotfiles with no other dot
/// (".zshrc"), and names ending in a dot. The treemap's `TypeColor` reads
/// names by the same rule.
pub fn extension(name: &[u8]) -> Option<&[u8]> {
    let dot = name.iter().rposition(|&b| b == b'.')?;
    (dot > 0 && dot + 1 < name.len()).then(|| &name[dot + 1..])
}

/// Extensions of up to 16 bytes, ASCII-lowercased and packed big-endian.
/// Names hold no zero bytes, so distinct extensions never share a key and
/// the bytes can be read back from it.
fn pack(ext: &[u8]) -> Option<u128> {
    (ext.len() <= 16).then(|| {
        ext.iter()
            .fold(0u128, |k, &b| k << 8 | b.to_ascii_lowercase() as u128)
    })
}

fn unpack(mut key: u128, out: &mut Vec<u8>) {
    let start = out.len();
    while key != 0 {
        out.push(key as u8);
        key >>= 8;
    }
    out[start..].reverse();
}

/// One multiply for a packed key; std's SipHash was most of the pass.
#[derive(Default)]
struct KeyHasher(u64);

impl Hasher for KeyHasher {
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ b as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
    }
    fn write_u128(&mut self, v: u128) {
        self.0 =
            (v as u64 ^ ((v >> 64) as u64).rotate_left(29)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    }
    fn finish(&self) -> u64 {
        self.0 ^ self.0 >> 31
    }
}

type Map<K> = HashMap<K, (u64, u64), BuildHasherDefault<KeyHasher>>;

/// Running totals, keyed by packed extension; longer extensions (rare) by bytes.
#[derive(Default)]
struct Totals {
    short: Map<u128>,
    long: Map<Vec<u8>>,
}

impl Totals {
    fn add(&mut self, name: &[u8], alloc: u64) {
        let ext = extension(name).unwrap_or_default();
        let slot = match pack(ext) {
            Some(key) => self.short.entry(key).or_default(),
            None => self.long.entry(ext.to_ascii_lowercase()).or_default(),
        };
        slot.0 += alloc;
        slot.1 += 1;
    }

    /// Folds the smaller map into the larger one.
    fn merge(self, other: Totals) -> Totals {
        let (mut big, small) = if self.short.len() >= other.short.len() {
            (self, other)
        } else {
            (other, self)
        };
        for (k, (a, n)) in small.short {
            let slot = big.short.entry(k).or_default();
            slot.0 += a;
            slot.1 += n;
        }
        for (k, (a, n)) in small.long {
            let slot = big.long.entry(k).or_default();
            slot.0 += a;
            slot.1 += n;
        }
        big
    }
}

impl Tree {
    /// Every file under `root` (or `root` itself, if a file), totalled by
    /// extension in one pass over the leaves. Directory totals already count
    /// a hard-linked file's bytes once, so the rows add up to `alloc[root]`
    /// and `n_files[root]`.
    pub fn types(&self, root: usize) -> Breakdown {
        let mut totals = Totals::default();
        if root < self.len() {
            if self.is_dir(root) {
                totals = self.totals_under(root);
            } else {
                totals.add(self.name_bytes(root), self.alloc[root]);
            }
        }
        let mut rows: Vec<(Vec<u8>, u64, u64)> =
            Vec::with_capacity(totals.short.len() + totals.long.len());
        for (key, (alloc, files)) in totals.short {
            let mut ext = Vec::new();
            unpack(key, &mut ext);
            rows.push((ext, alloc, files));
        }
        rows.extend(
            totals
                .long
                .into_iter()
                .map(|(ext, (alloc, files))| (ext, alloc, files)),
        );
        rows.sort_unstable_by(|a, b| {
            b.1.cmp(&a.1)
                .then(b.2.cmp(&a.2))
                .then_with(|| a.0.cmp(&b.0))
        });

        let mut out = Breakdown {
            ext_off: Vec::with_capacity(rows.len() + 1),
            ..Default::default()
        };
        out.ext_off.push(0);
        for (ext, alloc, files) in rows {
            out.ext_blob.extend_from_slice(&ext);
            out.ext_off.push(out.ext_blob.len() as u32);
            out.alloc.push(alloc);
            out.files.push(files);
        }
        out
    }

    /// Files below directory `dir`. Big folders fan their children out
    /// across threads; the rest walk an explicit stack (no deep recursion).
    fn totals_under(&self, dir: usize) -> Totals {
        let visit = |mut totals: Totals, k: &u32| {
            let k = *k as usize;
            if !self.is_dir(k) {
                totals.add(self.name_bytes(k), self.alloc[k]);
            } else if self.n_files[k] >= PARALLEL_FILES {
                totals = totals.merge(self.totals_under(k));
            } else {
                let mut stack = vec![k];
                while let Some(d) = stack.pop() {
                    for &c in self.kids(d) {
                        let c = c as usize;
                        if self.is_dir(c) {
                            stack.push(c);
                        } else {
                            totals.add(self.name_bytes(c), self.alloc[c]);
                        }
                    }
                }
            }
            totals
        };
        let kids = self.kids(dir);
        if self.n_files[dir] >= PARALLEL_FILES {
            kids.par_iter()
                .fold(Totals::default, visit)
                .reduce(Totals::default, Totals::merge)
        } else {
            kids.iter().fold(Totals::default(), visit)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(b: &Breakdown) -> Vec<(String, u64, u64)> {
        (0..b.len())
            .map(|i| {
                (
                    String::from_utf8(b.ext(i).to_vec()).unwrap(),
                    b.alloc[i],
                    b.files[i],
                )
            })
            .collect()
    }

    #[test]
    fn extension_rule_matches_the_treemap() {
        let ext = |n: &str| extension(n.as_bytes()).map(|e| String::from_utf8(e.to_vec()).unwrap());
        assert_eq!(ext("photo.JPG").as_deref(), Some("JPG"));
        assert_eq!(ext("archive.tar.gz").as_deref(), Some("gz"));
        assert_eq!(ext(".zshrc"), None, "a dotfile has no extension");
        assert_eq!(ext(".config.json").as_deref(), Some("json"));
        assert_eq!(ext("Makefile"), None);
        assert_eq!(ext("trailing."), None);
        assert_eq!(ext("a.é").as_deref(), Some("é"));
    }

    #[test]
    fn packed_keys_round_trip_and_stay_distinct() {
        for ext in ["a", "jpg", "sixteen_bytes_16", "é", "ab"] {
            let key = pack(ext.as_bytes()).unwrap();
            let mut out = Vec::new();
            unpack(key, &mut out);
            assert_eq!(out, ext.as_bytes());
        }
        assert_ne!(pack(b"ab"), pack(b"b"));
        assert_eq!(pack(b"JPG"), pack(b"jpg"));
        assert_eq!(pack(b"seventeen_bytes_x"), None);
        assert_eq!(pack(b""), Some(0));
    }

    #[test]
    fn totals_by_extension_scoped_to_the_root_and_sorted_by_size() {
        let mut t = Tree::with_root("/r");
        let photos = t.push("photos", 0, 0, 0, true);
        let code = t.push("code", 0, 0, 0, true);
        t.push("README", 0, 7, 7, false);
        t.push("a.JPG", photos, 0, 100, false);
        t.push("b.jpg", photos, 0, 300, false);
        t.push(".hidden", photos, 0, 5, false);
        t.push("c.png", photos, 0, 300, false);
        t.push("main.rs", code, 0, 40, false);
        t.push("lib.rs", code, 0, 60, false);
        t.push("x.jpg", code, 0, 1, false);
        t.push("weird.a_very_long_extension_name", code, 0, 9, false);
        t.push("WEIRD.A_Very_Long_Extension_Name", code, 0, 1, false);
        // The scanner zeroes every hard link of a file but the first.
        t.push("hardlink-loser.jpg", code, 0, 0, false);
        crate::finish(&mut t);

        let all = t.types(0);
        assert_eq!(
            rows(&all),
            [
                ("jpg".into(), 401, 4),
                ("png".into(), 300, 1),
                ("rs".into(), 100, 2),
                ("".into(), 12, 2),
                ("a_very_long_extension_name".into(), 10, 2),
            ]
        );
        assert_eq!(all.alloc.iter().sum::<u64>(), t.alloc[0]);
        assert_eq!(all.files.iter().sum::<u64>(), t.n_files[0] as u64);

        // Scoped to one folder: its sibling's files are not counted.
        let only = t.types(photos as usize);
        assert_eq!(
            rows(&only),
            [
                ("jpg".into(), 400, 2),
                ("png".into(), 300, 1),
                ("".into(), 5, 1)
            ]
        );
        assert_eq!(only.alloc.iter().sum::<u64>(), t.alloc[photos as usize]);

        // A file as the root, and an index past the end.
        assert_eq!(rows(&t.types(3)), [("".into(), 7, 1)]);
        assert!(t.types(t.len()).is_empty());
    }

    #[test]
    fn parallel_and_serial_walks_agree() {
        // Breadth first, each folder's children in one batch as the walk
        // appends them; enough files that nested folders split too.
        let mut t = Tree::with_root("/r");
        let mut queue = std::collections::VecDeque::from([0u32]);
        let (mut dirs, mut file) = (1, 0usize);
        while let Some(d) = queue.pop_front() {
            for _ in 0..3 {
                if dirs < 40 {
                    queue.push_back(t.push(&format!("d{dirs}"), d, 0, 0, true));
                    dirs += 1;
                }
            }
            for _ in 0..4_000 {
                let ext = ["jpg", "rs", "TXT", "txt", "x", "", "seventeen_bytes_x"][file % 7];
                t.push(&format!("f{file}.{ext}"), d, 0, (file % 97) as u64, false);
                file += 1;
            }
        }
        crate::finish(&mut t);
        let nested = t
            .kids(0)
            .iter()
            .filter(|&&k| t.n_files[k as usize] >= PARALLEL_FILES)
            .count();
        assert!(
            nested > 0,
            "some folder below the root is split across threads too"
        );

        let fast = t.types(0);
        let mut slow: HashMap<Vec<u8>, (u64, u64)> = HashMap::new();
        for i in 1..t.len() {
            if !t.is_dir(i) {
                let ext = extension(t.name_bytes(i))
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                let s = slow.entry(ext).or_default();
                s.0 += t.alloc[i];
                s.1 += 1;
            }
        }
        assert_eq!(fast.len(), slow.len());
        for i in 0..fast.len() {
            assert_eq!(slow[fast.ext(i)], (fast.alloc[i], fast.files[i]));
        }
        assert!(fast.alloc.windows(2).all(|w| w[0] >= w[1]));
        assert_eq!(fast.alloc.iter().sum::<u64>(), t.alloc[0]);
        assert_eq!(fast.files.iter().sum::<u64>(), t.n_files[0] as u64);
    }
}
