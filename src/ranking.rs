//! "Largest first" selection over a finished scan. Ties break by path,
//! then node index, so parallel search chunks merge to the exact order a
//! serial sort produces.
use crate::Tree;
use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;

struct Ranked<'a> {
    tree: &'a Tree,
    node: usize,
    alloc: u64,
}

impl Ord for Ranked<'_> {
    #[inline]
    fn cmp(&self, other: &Self) -> Ordering {
        self.alloc
            .cmp(&other.alloc)
            .then_with(|| self.tree.path(other.node).cmp(&self.tree.path(self.node)))
            .then_with(|| self.node.cmp(&other.node))
    }
}

impl PartialOrd for Ranked<'_> {
    #[inline]
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for Ranked<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for Ranked<'_> {}

/// The `limit` best nodes by (allocated bytes, path, node index) seen so far.
pub(crate) struct TopK<'a> {
    scan: &'a Tree,
    limit: usize,
    heap: BinaryHeap<Reverse<Ranked<'a>>>,
    floor: u64,
}

impl<'a> TopK<'a> {
    pub(crate) fn new(scan: &'a Tree, limit: usize) -> Self {
        Self {
            scan,
            limit,
            heap: BinaryHeap::new(),
            floor: 0,
        }
    }

    #[inline]
    pub(crate) fn push(&mut self, node: usize) {
        if self.limit == 0 {
            return;
        }
        let alloc = self.scan.alloc[node];
        if alloc < self.floor {
            return;
        }
        let candidate = Ranked {
            tree: self.scan,
            node,
            alloc,
        };
        if self.heap.len() < self.limit {
            self.heap.push(Reverse(candidate));
        } else {
            match self.heap.peek_mut() {
                Some(mut weakest) if candidate > weakest.0 => *weakest = Reverse(candidate),
                _ => return,
            }
        }
        if self.heap.len() == self.limit {
            self.floor = self.heap.peek().map_or(0, |Reverse(minimum)| minimum.alloc);
        }
    }

    pub(crate) fn merge(mut self, other: Self) -> Self {
        for Reverse(ranked) in other.heap {
            self.push(ranked.node);
        }
        self
    }

    pub(crate) fn into_sorted(self) -> Vec<usize> {
        let mut best: Vec<_> = self.heap.into_iter().map(|item| item.0).collect();
        best.sort_unstable_by(|a, b| b.cmp(a));
        best.into_iter().map(|item| item.node).collect()
    }
}

/// The `limit` largest of `indices` by allocated bytes, largest first.
pub fn top_by_alloc(scan: &Tree, indices: impl Iterator<Item = usize>, limit: usize) -> Vec<usize> {
    let mut top = TopK::new(scan, limit);
    for i in indices {
        top.push(i);
    }
    top.into_sorted()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NO_PARENT;

    fn fixture(directories: usize, files: usize, ties: bool) -> Tree {
        let mut t = Tree {
            name_off: vec![0],
            ..Tree::default()
        };
        let mut push = |parent, name: &str, is_dir: bool, bytes| {
            t.parents.push(parent);
            t.flags.push(u8::from(is_dir));
            t.alloc.push(bytes);
            t.name_blob.extend_from_slice(name.as_bytes());
            t.name_off.push(t.name_blob.len() as u32);
        };
        push(NO_PARENT, "/fixture", true, 0);
        for d in 0..directories {
            push(0, &format!("project-{d:06}-é"), true, 0);
        }
        for d in 0..directories {
            for f in 0..files {
                let bytes = if ties {
                    4096
                } else {
                    ((f * 7919 + d * 104729) % 100_000) as u64 * 4096
                };
                push(d as u32 + 1, &format!("file-{f:06}-日本語"), false, bytes);
            }
        }
        t
    }

    #[test]
    fn bounded_order_matches_full_sort_in_both_visit_orders() {
        for ties in [true, false] {
            let t = fixture(13, 29, ties);
            for limit in [0, 1, 20, 1000] {
                let mut expected: Vec<_> = (1..t.len()).collect();
                expected.sort_unstable_by_key(|&i| (Reverse(t.alloc[i]), t.path(i), Reverse(i)));
                expected.truncate(limit);
                assert_eq!(top_by_alloc(&t, 1..t.len(), limit), expected);
                assert_eq!(top_by_alloc(&t, (1..t.len()).rev(), limit), expected);
            }
        }
    }
}
