// C bridge to the blitztree Rust scan engine.
#ifndef BZ_H
#define BZ_H

#include <stdint.h>

typedef struct BzScan BzScan;

BzScan *bz_scan_start(const char *path);
void bz_progress(BzScan *h, uint64_t *files, uint64_t *dirs, uint64_t *bytes, int *done);
uint64_t bz_take_tree(BzScan *h);

const uint32_t *bz_parents(BzScan *h);
const uint64_t *bz_alloc(BzScan *h);
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

// Largest files anywhere in the scan (directories excluded), selected in the
// engine without copying the tree: the same function behind the CLI's
// `largest_files`. Nodes are tree indices, largest first, valid until
// bz_largest_free. NULL before a finished scan.
typedef struct BzLargest BzLargest;
BzLargest *bz_largest_files(BzScan *h, uint32_t limit, uint64_t min_bytes);
uint32_t bz_largest_count(BzLargest *l);
const uint32_t *bz_largest_nodes(BzLargest *l);
void bz_largest_free(BzLargest *l);

// Allocated bytes and file counts per extension under node `root`, largest
// first. Row i's extension is ext_blob[ext_off[i]..ext_off[i+1]], ASCII
// lowercase, empty for files without one. NULL without a tree or for a node
// outside it. Buffers live until bz_types_free.
typedef struct BzTypes BzTypes;
BzTypes *bz_types(BzScan *h, uint32_t root);
uint32_t bz_types_count(BzTypes *t);
const uint32_t *bz_types_ext_off(BzTypes *t); // length count+1
const uint8_t *bz_types_ext_blob(BzTypes *t);
const uint64_t *bz_types_alloc(BzTypes *t);
const uint64_t *bz_types_files(BzTypes *t);
void bz_types_free(BzTypes *t);

void bz_free(BzScan *h);

#endif
