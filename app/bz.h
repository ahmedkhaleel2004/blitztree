// C bridge to the blitztree Rust scan engine.
#ifndef BZ_H
#define BZ_H

#include <stdbool.h>
#include <stdint.h>

typedef struct BzScan BzScan;

// NULL for a NULL or empty path, or when the scan thread cannot start: that is
// a failed scan, there is no handle to poll. The path bytes are used exactly
// (not necessarily UTF-8); a symlink in them is followed, and the root node
// keeps the name it was given.
BzScan *bz_scan_start(const char *path);
// `done` is set once the scan has ended, with or without a tree: finished,
// cancelled or failed (a NULL handle also reports done). Any output pointer
// may be NULL.
void bz_progress(BzScan *h, uint64_t *files, uint64_t *dirs, uint64_t *bytes, int *done);

// How a scan stands, from bz_scan_status.
enum {
    BZ_SCAN_RUNNING = 0,   // the scan thread is still working
    BZ_SCAN_DONE = 1,      // a tree was built; bz_take_tree returns its nodes
    BZ_SCAN_CANCELLED = 2, // bz_cancel cut the walk short; there is no tree
    BZ_SCAN_FAILED = 3,    // an internal error (logged to stderr); no tree
};
// One of the BZ_SCAN_* values. Anything but BZ_SCAN_RUNNING matches done=1
// in bz_progress. A NULL handle is BZ_SCAN_FAILED. Read it after done to tell
// a stopped scan from a failed one: both have no tree.
int bz_scan_status(BzScan *h);
// Ask a running scan to stop. It reads no further folder and ends promptly
// (the folders being read at that moment finish) with BZ_SCAN_CANCELLED and
// no tree: a partial tree is never handed over as the scan. Polling still
// finishes normally. Safe to repeat, and a no-op once the scan has finished.
void bz_cancel(BzScan *h);

// Node count of the finished tree. 0 means there is none: a scan that failed
// (an internal error, logged to stderr), was cancelled, has a NULL handle, or
// is not done yet. A handle with 0 nodes is only for bz_free.
uint64_t bz_take_tree(BzScan *h);

const uint32_t *bz_parents(BzScan *h);
const uint64_t *bz_alloc(BzScan *h);
const uint64_t *bz_logical(BzScan *h);
const uint32_t *bz_nfiles(BzScan *h);
// bit0 = is_dir; bit1 = this node's own listing or entry was partial.
const uint8_t *bz_flags(BzScan *h);
// One bool per node: true when everything in the subtree below was read. A
// folder whose own listing was partial has flags bit1 set as well; one that is
// only false through a child does not. NULL before bz_take_tree.
const bool *bz_complete(BzScan *h);
const uint32_t *bz_child_off(BzScan *h); // length N+1
const uint32_t *bz_children(BzScan *h);
const uint32_t *bz_name_off(BzScan *h); // length N+1
const uint8_t *bz_name_blob(BzScan *h);
// Same as bz_coverage's `errors`.
uint64_t bz_errors(BzScan *h);

// What a finished scan could not read: the same account the CLI prints as
// `coverage` in its JSON (the engine builds both from one function).
typedef struct {
    uint64_t errors;                    // failed reads of every kind (bz_errors)
    uint64_t entry_errors;              // entries unreadable or malformed
    uint64_t invalid_names;             // entries dropped for a non-UTF-8 name; they and what is below them are missing
    uint64_t skipped_cloud_directories; // cloud-only folders left unread (reading would download them)
    uint64_t skipped_mount_points;      // mount points left unread (a scan measures one volume)
    bool complete;                      // every folder was read in full (bz_complete of the root)
} BzCoverage;
// Fill `out` and return true. Returns false and leaves `out` untouched for a
// NULL handle, a NULL `out`, or a handle without a tree (before
// bz_take_tree, or a cancelled or failed scan).
bool bz_coverage(BzScan *h, BzCoverage *out);

// Shared Clean Up results, sorted by size. Buffers/labels live until bz_free.
// Only read cleanup_nodes[0..cleanup_count]; an empty list has count zero.
uint64_t bz_cleanup_count(BzScan *h);
const uint32_t *bz_cleanup_nodes(BzScan *h);
// index is a candidate-list index, not a tree node index. NULL out of range.
const char *bz_cleanup_description(BzScan *h, uint64_t index);

// Release a handle and its buffers (pointers read from it are dead after).
// A scan that is still running is asked to stop first, as by bz_cancel: its
// thread keeps its own references and ends on its own, discarding the result.
// Do not call it concurrently with any other function on the same handle.
void bz_free(BzScan *h);

#endif
