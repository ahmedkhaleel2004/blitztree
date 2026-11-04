//! Read-only reports for agents. Suggestions are review candidates, not delete permissions.
use blitztree::{cleanup, Tree};
use serde_json::{json, Value};
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::path::PathBuf;

pub struct Options {
    pub min_bytes: u64,
    pub limit: usize,
}

fn entry(t: &Tree, i: usize) -> Value {
    let is_dir = t.is_dir(i);
    json!({
        "path": t.path(i), "kind": if is_dir { "directory" } else { "file_or_link" },
        "allocated_bytes": t.alloc[i], "logical_bytes": t.logical[i],
        "unique_bytes": t.unique[i], "cloned_bytes": t.cloned(i),
        "file_count": if is_dir { t.n_files[i] } else { 1 },
        "complete": t.complete[i],
    })
}

fn ordered(scan: &Tree, indices: impl Iterator<Item = usize>, limit: usize) -> Vec<usize> {
    if limit == 0 {
        return Vec::new();
    }
    // Keep only the requested top K, even for millions of equally sized files.
    let mut heap: BinaryHeap<Reverse<(u64, Reverse<PathBuf>, usize)>> = BinaryHeap::new();
    for i in indices {
        let alloc = scan.alloc[i];
        if heap.len() == limit
            && heap
                .peek()
                .is_some_and(|Reverse((minimum, _, _))| alloc < *minimum)
        {
            continue;
        }
        let candidate = (alloc, Reverse(scan.path(i)), i);
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
        "sort": "unique_bytes descending, path ascending",
        "reclaimable_bytes": Value::Null,
        "note": "These are the Clean Up panel's name/structure heuristics, not a safety assessment. They do not check project activity, ownership, local edits or reproducibility. Review each path and stop the owning app/tool before considering removal. Incomplete candidates have partial sizes. Allocated bytes are footprint, not guaranteed recoverable space; hard links, APFS clones/snapshots and open files affect recovery. Unique bytes count each APFS clone family's shared blocks once. Moving to Trash alone does not free space. No action is authorized by this report."
    })
}
