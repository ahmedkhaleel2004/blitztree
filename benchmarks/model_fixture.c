#include "../app/bz.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/*
 * A one-node scan adapter for the headless hand-off test.  It deliberately
 * does no filesystem work: the Swift harness supplies temporary directory
 * names only to distinguish the delayed volume snapshots.
 */
struct BzScan {
    uint32_t *parents;
    uint64_t *alloc;
    uint64_t *logical;
    uint32_t *nfiles;
    uint8_t *flags;
    uint32_t *child_off;
    uint32_t *children;
    uint32_t *name_off;
    uint8_t *name_blob;
    size_t name_length;
};

static uint32_t free_count;

static void *zeroed(size_t count, size_t size) {
    void *result = calloc(count ? count : 1, size ? size : 1);
    if (!result) abort();
    return result;
}

BzScan *bz_scan_start(const char *path) {
    BzScan *h = zeroed(1, sizeof(*h));
    h->parents = zeroed(1, sizeof(*h->parents));
    h->parents[0] = UINT32_MAX;
    h->alloc = zeroed(1, sizeof(*h->alloc));
    h->alloc[0] = 1;
    h->logical = zeroed(1, sizeof(*h->logical));
    h->logical[0] = 1;
    h->nfiles = zeroed(1, sizeof(*h->nfiles));
    h->flags = zeroed(1, sizeof(*h->flags));
    h->flags[0] = 1;
    h->child_off = zeroed(2, sizeof(*h->child_off));
    h->children = zeroed(1, sizeof(*h->children));

    h->name_length = strlen(path);
    h->name_off = zeroed(2, sizeof(*h->name_off));
    h->name_off[1] = (uint32_t)h->name_length;
    h->name_blob = zeroed(h->name_length, sizeof(*h->name_blob));
    memcpy(h->name_blob, path, h->name_length);
    return h;
}

void bz_progress(BzScan *h, uint64_t *files, uint64_t *dirs,
                 uint64_t *bytes, int *done) {
    (void)h;
    *files = 0;
    *dirs = 1;
    *bytes = 1;
    *done = 1;
}

uint64_t bz_take_tree(BzScan *h) { return 1; }
const uint32_t *bz_parents(BzScan *h) { return h->parents; }
const uint64_t *bz_alloc(BzScan *h) { return h->alloc; }
const uint64_t *bz_logical(BzScan *h) { return h->logical; }
const uint32_t *bz_nfiles(BzScan *h) { return h->nfiles; }
const uint8_t *bz_flags(BzScan *h) { return h->flags; }
const uint32_t *bz_child_off(BzScan *h) { return h->child_off; }
const uint32_t *bz_children(BzScan *h) { return h->children; }
const uint32_t *bz_name_off(BzScan *h) { return h->name_off; }
const uint8_t *bz_name_blob(BzScan *h) { return h->name_blob; }
uint64_t bz_errors(BzScan *h) { (void)h; return 0; }
uint64_t bz_cleanup_count(BzScan *h) { (void)h; return 0; }
const uint32_t *bz_cleanup_nodes(BzScan *h) { return h->children; }
const char *bz_cleanup_description(BzScan *h, uint64_t index) {
    (void)h; (void)index; return NULL;
}

void bz_free(BzScan *h) {
    if (!h) return;
    free_count += 1;
    free(h->parents);
    free(h->alloc);
    free(h->logical);
    free(h->nfiles);
    free(h->flags);
    free(h->child_off);
    free(h->children);
    free(h->name_off);
    free(h->name_blob);
    free(h);
}

uint32_t bz_fixture_free_count(void) { return free_count; }
