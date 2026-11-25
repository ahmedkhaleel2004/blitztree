//! Read-only reports for agents. Suggestions are review candidates, not delete permissions.
use blitztree::ranking::{largest_directories, largest_files, top_by_alloc};
use blitztree::{cleanup, Tree};
use serde_json::{json, Value};

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

pub fn inventory(scan: &Tree, options: &Options) -> Value {
    let children = top_by_alloc(
        scan,
        scan.kids(0).iter().map(|&i| i as usize),
        options.limit,
    );
    let files = largest_files(scan, options.min_bytes, options.limit);
    let directories = largest_directories(scan, options.min_bytes, options.limit);
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
