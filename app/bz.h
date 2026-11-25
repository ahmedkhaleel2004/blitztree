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

void bz_free(BzScan *h);

typedef struct BzSearch BzSearch;

// Interactive search over all nodes in the tree, off main thread.
// query: UTF-8 search pattern (substring or wildcard with * and ?).
// limit: max results to return (sorted largest size first).
BzSearch *bz_search(BzScan *h, const char *query, uint32_t limit);
uint64_t bz_search_total_matches(BzSearch *s);
uint32_t bz_search_result_count(BzSearch *s);
const uint32_t *bz_search_result_nodes(BzSearch *s);
void bz_search_free(BzSearch *s);

#endif
