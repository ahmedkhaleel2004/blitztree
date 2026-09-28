//! Read-only reports for agents. Suggestions are review candidates, not delete permissions.
use blitztree::{cleanup, Tree};
use serde_json::{json, Value};
use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;

pub struct Options {
    pub min_bytes: u64,
    pub limit: usize,
}

fn entry(t: &Tree, i: usize) -> Value {
    let is_dir = t.is_dir(i);
    json!({
        "path": t.path(i), "kind": if is_dir { "directory" } else { "file_or_link" },
        "allocated_bytes": t.alloc[i], "logical_bytes": t.logical[i],
        "file_count": if is_dir { t.n_files[i] } else { 1 },
        "complete": t.complete[i],
    })
}

// Every entry in a heap refers to the same immutable scan.
struct Ranked<'a> {
    tree: &'a Tree,
    node: usize,
}

impl Ord for Ranked<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        self.tree.alloc[self.node]
            .cmp(&other.tree.alloc[other.node])
            .then_with(|| self.tree.compare_paths(other.node, self.node))
            .then_with(|| self.node.cmp(&other.node))
    }
}

impl PartialOrd for Ranked<'_> {
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

fn ordered(scan: &Tree, indices: impl Iterator<Item = usize>, limit: usize) -> Vec<usize> {
    if limit == 0 {
        return Vec::new();
    }
    // Keep only the requested top K, even for millions of equally sized files.
    let mut heap: BinaryHeap<Reverse<Ranked<'_>>> = BinaryHeap::new();
    for i in indices {
        let alloc = scan.alloc[i];
        if heap.len() == limit
            && heap
                .peek()
                .is_some_and(|Reverse(minimum)| alloc < scan.alloc[minimum.node])
        {
            continue;
        }
        let candidate = Ranked { tree: scan, node: i };
        if heap.len() < limit {
            heap.push(Reverse(candidate));
        } else if candidate > heap.peek().unwrap().0 {
            heap.pop();
            heap.push(Reverse(candidate));
        }
    }
    let mut best: Vec<_> = heap.into_iter().map(|item| item.0).collect();
    best.sort_unstable_by(|a, b| b.cmp(a));
    best.into_iter().map(|item| item.node).collect()
}

pub fn inventory(scan: &Tree, options: &Options) -> Value {
    let children = ordered(
        scan,
        scan.kids(0).iter().map(|&i| i as usize),
        options.limit,
    );
    let files = ordered(
        scan,
        (1..scan.len())
            .filter(|&i| !scan.is_dir(i) && scan.alloc[i] >= options.min_bytes),
        options.limit,
    );
    let directories = ordered(
        scan,
        (1..scan.len())
            .filter(|&i| scan.is_dir(i) && scan.alloc[i] >= options.min_bytes),
        options.limit,
    );
    json!({
        "largest_children": children.into_iter().map(|i| entry(scan, i)).collect::<Vec<_>>(),
        "largest_directories": directories.into_iter().map(|i| entry(scan, i)).collect::<Vec<_>>(),
        "largest_files": files.into_iter().map(|i| entry(scan, i)).collect::<Vec<_>>(),
        "note": "Inventory is descriptive, not cleanup advice. Directories can contain other listed directories/files: these entries overlap and must not be added together."
    })
}

pub fn quick_wins(scan: &Tree, options: &Options) -> Value {
    let candidates = cleanup::find(scan, options.min_bytes);
    let candidate_allocated_bytes: u64 = candidates
        .iter()
        .map(|c| scan.alloc[c.node as usize])
        .sum();
    let displayed_allocated_bytes: u64 = candidates
        .iter()
        .take(options.limit)
        .map(|c| scan.alloc[c.node as usize])
        .sum();
    let displayed: Vec<Value> = candidates
        .iter()
        .take(options.limit)
        .map(|c| {
            let mut value = entry(scan, c.node as usize);
            value["category"] = json!(c.kind.id());
            value["reason"] = json!(c.kind.description());
            value["requires_review"] = json!(true);
            value
        })
        .collect();
    json!({
        "candidates": displayed, "candidate_count": candidates.len(),
        "truncated": candidates.len() > options.limit,
        "candidate_allocated_bytes": candidate_allocated_bytes,
        "displayed_allocated_bytes": displayed_allocated_bytes,
        "inventory": inventory(scan, options),
        "scope": "The same folder recognition as the Clean Up panel, within the requested scan root. The root itself is not a candidate.",
        "sort": "allocated_bytes descending, path ascending",
        "reclaimable_bytes": Value::Null,
        "note": "These are the Clean Up panel's name/structure heuristics, not a safety assessment. They do not check project activity, ownership, local edits or reproducibility. Review each path and stop the owning app/tool before considering removal. Incomplete candidates have partial sizes. Allocated bytes are footprint, not guaranteed recoverable space; hard links, APFS clones/snapshots and open files affect recovery. Moving to Trash alone does not free space. No action is authorized by this report."
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use blitztree::NO_PARENT;
    use std::hint::black_box;
    use std::path::PathBuf;
    use std::time::Instant;

    fn fixture(directories: usize, files: usize, ties: bool) -> Tree {
        let mut t = Tree { name_off: vec![0], ..Tree::default() };
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
                let bytes = if ties { 4096 } else { ((f * 7919 + d * 104729) % 100_000) as u64 * 4096 };
                push(d as u32 + 1, &format!("file-{f:06}-日本語"), false, bytes);
            }
        }
        t
    }

    // Exact pre-change bounded heap, retained only as a benchmark reference.
    fn reference(t: &Tree, indices: impl Iterator<Item = usize>, limit: usize) -> Vec<usize> {
        if limit == 0 { return Vec::new(); }
        let mut heap: BinaryHeap<Reverse<(u64, Reverse<PathBuf>, usize)>> = BinaryHeap::new();
        for i in indices {
            let alloc = t.alloc[i];
            if heap.len() == limit && heap.peek().is_some_and(|Reverse((minimum, _, _))| alloc < *minimum) {
                continue;
            }
            let candidate = (alloc, Reverse(t.path(i)), i);
            if heap.len() < limit {
                heap.push(Reverse(candidate));
            } else if candidate > heap.peek().unwrap().0 {
                heap.pop();
                heap.push(Reverse(candidate));
            }
        }
        let mut best: Vec<_> = heap.into_iter().map(|item| item.0).collect();
        best.sort_unstable_by(|a, b| b.cmp(a));
        best.into_iter().map(|item| item.2).collect()
    }

    #[test]
    fn bounded_order_matches_full_sort_in_both_visit_orders() {
        for ties in [true, false] {
            let t = fixture(13, 29, ties);
            for limit in [0, 1, 20, 1000] {
                let mut expected: Vec<_> = (1..t.len()).collect();
                expected.sort_unstable_by_key(|&i| (Reverse(t.alloc[i]), t.path(i), Reverse(i)));
                expected.truncate(limit);
                assert_eq!(ordered(&t, 1..t.len(), limit), expected);
                assert_eq!(ordered(&t, (1..t.len()).rev(), limit), expected);
            }
        }
    }

    #[test]
    #[ignore = "opt-in timing benchmark; run alone with --nocapture"]
    fn report_order_benchmark() {
        for (name, dirs, files, ties) in [
            ("wide-equal", 1, 250_000, true),
            ("projects-equal", 1000, 250, true),
            ("projects-varied", 1000, 250, false),
        ] {
            let t = fixture(dirs, files, ties);
            let expected = reference(&t, dirs + 1..t.len(), 20);
            assert_eq!(ordered(&t, dirs + 1..t.len(), 20), expected);
            let mut samples = [Vec::new(), Vec::new()];
            for round in 0..10 {
                for which in if round % 2 == 0 { [0, 1] } else { [1, 0] } {
                    let start = Instant::now();
                    let found = if which == 0 {
                        reference(black_box(&t), dirs + 1..t.len(), black_box(20))
                    } else {
                        ordered(black_box(&t), dirs + 1..t.len(), black_box(20))
                    };
                    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
                    assert_eq!(found, expected);
                    if round > 0 { samples[which].push(elapsed); }
                }
            }
            println!("{name} nodes={} baseline_ms={:?} candidate_ms={:?}", t.len(), samples[0], samples[1]);
        }
    }
}
