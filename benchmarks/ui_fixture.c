#include "ui_fixture.h"
#include <stdlib.h>
#include <string.h>

struct BzScan {
    uint32_t count, cleanup_count;
    uint32_t *cleanup_nodes;
    char **cleanup_descriptions;
    uint32_t *parents, *nfiles, *child_off, *children, *name_off;
    uint64_t *alloc;
    uint8_t *flags, *name_blob;
};
static void *copied(const void *source, size_t bytes) {
    void *result = malloc(bytes ? bytes : 1);
    if (!result) abort();
    if (bytes) memcpy(result, source, bytes);
    return result;
}
BzScan *bz_fixture_create(uint32_t n, const uint32_t *parents,
                         const uint64_t *alloc, const uint8_t *flags,
                         const uint32_t *child_off, const uint32_t *children,
                         const uint32_t *name_off, const uint8_t *name_blob) {
    BzScan *h = calloc(1, sizeof(*h));
    if (!h) abort();
    h->count = n;
    h->cleanup_nodes = copied(NULL, 0);
    h->parents = copied(parents, n * sizeof(*parents));
    h->alloc = copied(alloc, n * sizeof(*alloc));
    h->flags = copied(flags, n * sizeof(*flags));
    h->nfiles = calloc(n, sizeof(*h->nfiles));
    h->child_off = copied(child_off, (n + 1) * sizeof(*child_off));
    h->children = copied(children, child_off[n] * sizeof(*children));
    h->name_off = copied(name_off, (n + 1) * sizeof(*name_off));
    h->name_blob = copied(name_blob, name_off[n]);
    return h;
}
BzScan *bz_scan_start(const char *path) { (void)path; abort(); }
void bz_progress(BzScan *h, uint64_t *f, uint64_t *d, uint64_t *b, int *done) {
    (void)h; *f = 0; *d = 0; *b = 0; *done = 1;
}
uint64_t bz_take_tree(BzScan *h) { return h->count; }
const uint32_t *bz_parents(BzScan *h) { return h->parents; }
const uint64_t *bz_alloc(BzScan *h) { return h->alloc; }
const uint64_t *bz_logical(BzScan *h) { return h->alloc; }
const uint32_t *bz_nfiles(BzScan *h) { return h->nfiles; }
const uint8_t *bz_flags(BzScan *h) { return h->flags; }
const uint32_t *bz_child_off(BzScan *h) { return h->child_off; }
const uint32_t *bz_children(BzScan *h) { return h->children; }
const uint32_t *bz_name_off(BzScan *h) { return h->name_off; }
const uint8_t *bz_name_blob(BzScan *h) { return h->name_blob; }
uint64_t bz_errors(BzScan *h) { (void)h; return 0; }
void bz_fixture_add_cleanup(BzScan *h, uint32_t node, const char *description) {
    uint32_t n = h->cleanup_count;
    h->cleanup_nodes = realloc(h->cleanup_nodes, (n + 1) * sizeof(*h->cleanup_nodes));
    h->cleanup_descriptions = realloc(h->cleanup_descriptions, (n + 1) * sizeof(*h->cleanup_descriptions));
    if (!h->cleanup_nodes || !h->cleanup_descriptions) abort();
    h->cleanup_nodes[n] = node;
    h->cleanup_descriptions[n] = strdup(description);
    if (!h->cleanup_descriptions[n]) abort();
    h->cleanup_count += 1;
}
uint64_t bz_cleanup_count(BzScan *h) { return h->cleanup_count; }
const uint32_t *bz_cleanup_nodes(BzScan *h) { return h->cleanup_nodes; }
const char *bz_cleanup_description(BzScan *h, uint64_t index) {
    return index < h->cleanup_count ? h->cleanup_descriptions[index] : NULL;
}
// Synthetic candidates carry only a description: report them as one safe
// build kind with no verifier, and out-of-range like the engine does.
const char *bz_cleanup_kind_id(BzScan *h, uint64_t index) {
    return index < h->cleanup_count ? "fixture" : NULL;
}
const char *bz_cleanup_section_id(BzScan *h, uint64_t index) {
    return index < h->cleanup_count ? "build" : NULL;
}
uint8_t bz_cleanup_group(BzScan *h, uint64_t index) {
    return index < h->cleanup_count ? 0 : 255;
}
const char *bz_cleanup_verify(BzScan *h, uint64_t index) {
    return index < h->cleanup_count ? "" : NULL;
}
void bz_free(BzScan *h) {
    if (!h) return;
    for (uint32_t i = 0; i < h->cleanup_count; ++i) free(h->cleanup_descriptions[i]);
    free(h->cleanup_descriptions); free(h->cleanup_nodes);
    free(h->parents); free(h->alloc); free(h->flags); free(h->nfiles);
    free(h->child_off); free(h->children); free(h->name_off); free(h->name_blob); free(h);
}
