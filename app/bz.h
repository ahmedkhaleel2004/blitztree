// C bridge to the blitztree Rust scan engine.
#ifndef BZ_H
#define BZ_H

#include <stdint.h>

typedef struct BzScan BzScan;

BzScan *bz_scan_start(const char *path);
void bz_progress(BzScan *h, uint64_t *files, uint64_t *dirs, uint64_t *bytes, int *done);
uint64_t bz_take_tree(BzScan *h);

const uint32_t *bz_parents(BzScan *h);
const uint64_t *bz_alloc(BzScan *h); // allocated bytes, every APFS clone counted
const uint64_t *bz_unique(BzScan *h); // allocated bytes, APFS clones counted once
const uint64_t *bz_logical(BzScan *h);
const uint32_t *bz_nfiles(BzScan *h);
const uint8_t *bz_flags(BzScan *h); // bit0 = is_dir
const uint32_t *bz_child_off(BzScan *h); // length N+1
const uint32_t *bz_children(BzScan *h);
const uint32_t *bz_name_off(BzScan *h); // length N+1
const uint8_t *bz_name_blob(BzScan *h);
uint64_t bz_errors(BzScan *h);

// Shared Clean Up results, sorted by size. Buffers/labels live until bz_free.
// Only read cleanup_nodes[0..cleanup_count]; an empty list has count zero.
uint64_t bz_cleanup_count(BzScan *h);
const uint32_t *bz_cleanup_nodes(BzScan *h);
// index is a candidate-list index, not a tree node index. NULL out of range.
const char *bz_cleanup_description(BzScan *h, uint64_t index);

// Writes count values: what deleting each node frees. Blocks shared with APFS
// clones don't count. Nodes must not contain one another. Reads partly cloned
// files' attributes, so prefer calling it off the main thread. A handle from
// bz_cache_load reads nothing and counts partly cloned files as not freed.
void bz_reclaimable(BzScan *h, const uint32_t *nodes, uint64_t count, uint64_t *out);

// The last finished scan of a folder, saved to disk. bz_cache_load returns a
// finished handle (call bz_take_tree as after a scan), or NULL when there is
// no usable file: missing, damaged, another format version, or another
// folder or volume. Both are slow on big trees; call them off the main thread.
BzScan *bz_cache_load(const char *cache_path, const char *root);
// Needs the tree taken. Writes a temporary file, then renames it into
// place. Returns 0, or -1 after logging why.
int bz_cache_save(BzScan *h, const char *cache_path);
// When the handle's scan started, in seconds since 1970.
double bz_scanned_at(BzScan *h);

void bz_free(BzScan *h);

#endif
