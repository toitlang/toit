// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.
//
// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Copyright (C) 2026 Toit contributors.

#include "cmpctmalloc.h"

#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "FreeRTOS.h"
#include "task.h"

typedef uintptr_t addr_t;
typedef uintptr_t vaddr_t;

#define LTRACEF(...)
#define LTRACE_ENTRY
#define DEBUG_ASSERT assert
#define ASSERT(x) do {} while(false)
#define USE(x) ((void)(x))
#define STATIC_ASSERT(condition)
#define dprintf(...) fprintf(__VA_ARGS__)
#define INFO stdout

// Safe locking: before the scheduler starts, no locking is needed
// (single-threaded context). After the scheduler starts, use
// vTaskSuspendAll/xTaskResumeAll.
static inline void multi_heap_lock(void) {
    if (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) {
        vTaskSuspendAll();
    }
}
static inline void multi_heap_unlock(void) {
    if (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) {
        xTaskResumeAll();
    }
}
#define MULTI_HEAP_LOCK(x) multi_heap_lock()
#define MULTI_HEAP_UNLOCK(x) multi_heap_unlock()

#define IRAM_ATTR

// Thread tag map for associating tasks with tags.
// On ESP32 this uses FreeRTOS thread-local storage, but the EC618 FreeRTOS
// port does not have enough TLS slots, so we use a simple map instead.
#define MAX_TAG_ENTRIES 16
static struct { void *task; void *tag; } tag_map[MAX_TAG_ENTRIES];

static void *get_thread_tag(void) {
    void *task = xTaskGetCurrentTaskHandle();
    if (task == NULL) return NULL;
    for (int i = 0; i < MAX_TAG_ENTRIES; i++) {
        if (tag_map[i].task == task) return tag_map[i].tag;
    }
    return NULL;
}

#define GET_THREAD_LOCAL_TAG get_thread_tag()

#define ROUND_UP(x, alignment) (((x) + (alignment) - 1) & ~((alignment) - 1))
#define ROUND_DOWN(x, alignment) ((x) & ~((alignment) - 1))
#define IS_ALIGNED(x, alignment) (((x) & ((alignment) - 1)) == 0)
#ifdef MIN
#undef MIN
#endif
#ifdef MAX
#undef MAX
#endif
#define MIN(x, y) ((x) < (y) ? (x) : (y))
#define MAX(x, y) ((x) > (y) ? (x) : (y))
// Provoke crash.  Often because of a double free.
#define FATAL(reason) do { *(char *)(0xdeadf1ee) = 0; abort(); } while (0)
#define INLINE __attribute__((always_inline)) inline

// This is a two layer allocator.  Allocations that are a multiple of 4k in
// size or > 16336 bytes are allocated from a block allocator that gives out 4k
// aligned blocks.  Those less than 16336 bytes are allocated from cmpctmalloc.
// All allocations requesting a size divisible by 4k are fulfilled with
// addresses that are 4k aligned.

// Malloc implementation tuned for space.
//
// Allocation strategy takes place with a global mutex.  Freelist entries are
// kept in linked lists with 8 different sizes per binary order of magnitude
// and the header size is two words with eager coalescing on free.

void *cmpct_alloc(cmpct_heap_t *heap, size_t size);
void cmpct_free(cmpct_heap_t *heap, void *payload);
size_t cmpct_free_size_impl(cmpct_heap_t *heap);
size_t cmpct_get_allocated_size_impl(cmpct_heap_t *heap, void *p);
void cmpct_set_option(cmpct_heap_t *heap, int option, void *value);
void *cmpct_get_option(int option);
static void *page_alloc(cmpct_heap_t *heap, intptr_t pages, uintptr_t alignment, void *tag, bool for_malloc);
static void page_free(cmpct_heap_t *heap, void *address, int pages_unused, bool for_malloc);
struct header_struct;
struct free_struct;
static inline struct header_struct *right_header(struct header_struct *header);
static inline struct header_struct *left_header(struct header_struct *header);
static size_t page_number(cmpct_heap_t *heap, void *p);
static void *allocation_tail(cmpct_heap_t *heap, struct free_struct *head, size_t size, size_t rounded_up, int bucket);

#ifdef DEBUG
#define CMPCT_DEBUG
#endif

#define ALLOC_FILL 0x99
#define FREE_FILL 0x77
#define PADDING_FILL 0x55

#define PAGE_SIZE_SHIFT 12
#define PAGE_SIZE (1 << PAGE_SIZE_SHIFT)
#define IS_PAGE_ALIGNED(x) (((uintptr_t)(x) & (PAGE_SIZE - 1)) == 0)
#define PAGES_FOR_BYTES(x) (((x) + PAGE_SIZE - 1) >> PAGE_SIZE_SHIFT)

// Individual allocations above 16kbytes must be fetched directly from the
// block allocator.
#define HEAP_ALLOC_VIRTUAL_BITS 14
// The biggest allocation on a page is limited by size of the biggest bucket.
// With 8 buckets per order of magnitude the biggest bucket is bucket 7 (binary
// 111) and so follows the pattern 1 111 0*.  Bucket sizes don't include the
// header.
#define SMALL_ALLOCATION_LIMIT ((0xf << (HEAP_ALLOC_VIRTUAL_BITS - 4)))
#define ROUNDED_SMALL_ALLOCATION_LIMIT (1 << HEAP_ALLOC_VIRTUAL_BITS)

// Buckets for allocations.  The smallest 15 buckets are 8, 16, 24, etc. up to
// 120 bytes.  After that we round up to the nearest size that can be written
// /^0*1...0*$/, giving 8 buckets per order of binary magnitude.  The freelist
// entries in a given bucket have at least the given size, plus the header
// size.  On 64 bit, the 8 byte bucket is useless, since the freelist header
// is 16 bytes larger than the header, but we have it for simplicity.
#define NUMBER_OF_BUCKETS (1 + 15 + (HEAP_ALLOC_VIRTUAL_BITS - 7) * 8)

// Everything that happens on the heap is 8-byte aligned.
#define NATURAL_ALIGNMENT 8

// All individual memory areas on the heap start with this.
typedef struct header_struct {
    // This is divided up into two 16 bit fields, size and left_size.  We don't use actual
    // 16 bit fields because they don't work in IRAM, which is 32 bit only.
    // left_size: Used to find the previous memory area in address order.
    // size: For the next memory area.  Both size fields include the header.
    size_t size_;
    void *tag;  // Used for the pointer set by the user with heap_caps_set_option.
} header_t;

// On Cortex-M3 (EC618) we don't need the OBFUSCATE trick that prevents the
// Xtensa compiler from converting 32-bit loads to 16-bit loads.  Define as
// a no-op.
#define OBFUSCATE(variable)

static INLINE size_t get_left_size(header_t *header)
{
    size_t field = header->size_;
    OBFUSCATE(field);
    return field & 0xffff;
}

static INLINE void set_left_size(header_t *header, size_t size)
{
    size_t field = header->size_ & ~0xffff;
    OBFUSCATE(field);
    size_t result = field | size;
    OBFUSCATE(result);
    header->size_ = result;
}

static INLINE size_t get_size(header_t *header)
{
    size_t field = header->size_;
    OBFUSCATE(field);
    return field >> 16;
}

static INLINE void set_size(header_t *header, size_t size)
{
    ASSERT(size <= 0xffff);
    ASSERT((size & 1) == 0);
    size_t field = header->size_;
    OBFUSCATE(field);
    size_t result = (field & 0xffff) | (size << 16);
    OBFUSCATE(result);
    header->size_ = result;
}

typedef struct free_struct {
    header_t header;
    struct free_struct *next;  // Double linked list of free areas in the same bucket.
    struct free_struct *prev;
} free_t;

typedef enum {
    PAGE_FREE = 0,
    PAGE_IN_USE = 1,              // Page is first in an allocation.
    PAGE_IN_USE_FOR_MALLOCS = 2,  // Page is first in a malloc arena, used for smaller allocations.
    PAGE_CONTINUED = 3            // Page is subsequent in an allocation.
} page_use_t;

// For page allocator, not originally part of cmpctmalloc.  These fields are 32 bit
// so that they work in IRAM on ESP32.
typedef struct Page {
    uint32_t status;
    void *tag;           // Used for the pointer set by the user with heap_caps_set_option.
} Page;

// Allocation arenas are linked together with this header.
typedef struct arena_struct {
    struct arena_struct *previous;
    struct arena_struct *next;
} arena_t;

struct multi_heap_info {
    size_t size;
    size_t remaining;
    size_t free_blocks;
    size_t allocated_blocks;
    // Includes the array of struct Pages after this struct and some rounding.
    void *end_of_heap_structure;
    void *lock;
    void *ignore_free;  // Actually a bool, but use void* so that it works in IRAM.
    free_t *free_lists[NUMBER_OF_BUCKETS];
    // We have some 32 bit words that tell us whether there is an entry in the
    // freelist.
#define BUCKET_WORDS (((NUMBER_OF_BUCKETS) + 31) >> 5)
    uint32_t free_list_bits[BUCKET_WORDS];

    // Doubly linked list for allocation arenas.
    arena_t arenas;

    // For page allocator, not originally part of cmpctmalloc.
    int32_t number_of_pages;
    char *page_base;
    void *highest_address;
    // Actually has (number_of_pages + 1) elements.
    Page pages[1];
};

static ssize_t heap_grow(cmpct_heap_t *heap, free_t **bucket, int pages);

IRAM_ATTR static void lock(cmpct_heap_t *heap)
{
    MULTI_HEAP_LOCK(heap->lock);
}

IRAM_ATTR static void unlock(cmpct_heap_t *heap)
{
    MULTI_HEAP_UNLOCK(heap->lock);
}

static void dump_free(header_t *header)
{
    dprintf(INFO, "\t\tbase %p, end %p, len 0x%zx\n", header, right_header(header), get_size(header));
}

void cmpct_dump(cmpct_heap_t *heap)
{
    lock(heap);
    dprintf(INFO, "Heap dump (using cmpctmalloc):\n");
    dprintf(INFO, "\tsize %lu, remaining %lu, allocated_blocks %lu, free_blocks %lu\n",
            (unsigned long)heap->size,
            (unsigned long)heap->remaining,
            (unsigned long)heap->allocated_blocks,
            (unsigned long)heap->free_blocks);

    dprintf(INFO, "\tfree list:\n");
    for (int i = 0; i < NUMBER_OF_BUCKETS; i++) {
        bool header_printed = false;
        free_t *free_area = heap->free_lists[i];
        for (; free_area != NULL; free_area = free_area->next) {
            ASSERT(free_area != free_area->next);
            if (!header_printed) {
                dprintf(INFO, "\tbucket %d\n", i);
                header_printed = true;
            }
            dump_free(&free_area->header);
        }
    }
    unlock(heap);
}

// Operates in sizes that don't include the allocation header.
IRAM_ATTR static int size_to_index_helper(
    size_t size, size_t *rounded_up_out, int adjust, int increment)
{
    // First buckets are simply 8-spaced up to 128.
    if (size <= 128) {
        if (sizeof(size_t) == 8u && size <= sizeof(free_t) - sizeof(header_t)) {
            *rounded_up_out = sizeof(free_t) - sizeof(header_t);
        } else {
            *rounded_up_out = size;
        }
        // No allocation is smaller than 8 bytes, so the first bucket is for 8
        // byte spaces (not including the header).  For 64 bit, the free list
        // struct is 16 bytes larger than the header, so no allocation can be
        // smaller than that (otherwise how to free it), but we have empty 8
        // and 16 byte buckets for simplicity.
        return (size >> 3) - 1;
    }

    // We are going to go up to the next size to round up, but if we hit a
    // bucket size exactly we don't want to go up. By subtracting 8 here, we
    // will do the right thing (the carry propagates up for the round numbers
    // we are interested in).
    size += adjust;
    // After 128 the buckets are logarithmically spaced, every 16 up to 256,
    // every 32 up to 512 etc.  This can be thought of as rows of 8 buckets.
    // We use the compiler intrinsic count-leading-zeros to find the bucket.
    // Eg. 128-255 has 24 leading zeros and we want row to be 4.
    unsigned row = sizeof(size_t) * 8 - (4 + __builtin_clzl(size));
    // For row 4 we want to shift down 4 bits.
    unsigned column = (size >> row) & 7;
    int row_column = (row << 3) | column;
    row_column += increment;
    size = (8 + (row_column & 7)) << (row_column >> 3);
    *rounded_up_out = size;
    // We start with 15 buckets, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96,
    // 104, 112, 120.  Then we have row 4, sizes 128 and up, with the
    // row-column 8 and up.
    unsigned answer = row_column + 15 - 32;
    if (answer >= NUMBER_OF_BUCKETS) FATAL("Invalid size");
    return answer;
}

// Round up size to next bucket when allocating.
IRAM_ATTR static int size_to_index_allocating(size_t size, size_t *rounded_up_out)
{
    size_t rounded = ROUND_UP(size, NATURAL_ALIGNMENT);
    return size_to_index_helper(rounded, rounded_up_out, -8, 1);
}

// Round down size to next bucket when freeing.
IRAM_ATTR static int size_to_index_freeing(size_t size)
{
    size_t unused;
    return size_to_index_helper(size, &unused, 0, 0);
}

IRAM_ATTR inline static size_t tag_as_free(size_t left_size)
{
    return left_size | 1;
}

IRAM_ATTR inline static bool is_tagged_as_free(header_t *header)
{
    return (get_left_size(header) & 1) != 0;
}

IRAM_ATTR inline static size_t untag(size_t left_size)
{
    return left_size & ~1;
}

IRAM_ATTR inline static header_t *right_header(header_t *header)
{
    return (header_t *)((char *)header + get_size(header));
}

IRAM_ATTR inline static header_t *left_header(header_t *header)
{
    return (header_t *)((char *)header - (get_left_size(header) & ~1));
}

IRAM_ATTR inline static void set_free_list_bit(cmpct_heap_t *heap, int index)
{
    heap->free_list_bits[index >> 5] |= (1u << (31 - (index & 0x1f)));
}

IRAM_ATTR inline static void clear_free_list_bit(cmpct_heap_t *heap, int index)
{
    heap->free_list_bits[index >> 5] &= ~(1u << (31 - (index & 0x1f)));
}

IRAM_ATTR static int find_nonempty_bucket(cmpct_heap_t *heap, int index)
{
    uint32_t mask = (1u << (31 - (index & 0x1f))) - 1;
    mask = mask * 2 + 1;
    mask &= heap->free_list_bits[index >> 5];
    if (mask != 0) return (index & ~0x1f) + __builtin_clz(mask);
    for (index = ROUND_UP(index + 1, 32); index <= NUMBER_OF_BUCKETS; index += 32) {
        mask = heap->free_list_bits[index >> 5];
        if (mask != 0u) return index + __builtin_clz(mask);
    }
    return -1;
}

IRAM_ATTR static bool is_start_of_page_allocation(header_t *header)
{
    return get_left_size(header) == 0;
}

IRAM_ATTR static void create_free_area(cmpct_heap_t *heap, void *address, size_t left_size, size_t size, free_t **bucket)
{
    free_t *free_area = (free_t *)address;
    set_size(&free_area->header, size);
    set_left_size(&free_area->header, tag_as_free(left_size));
    if (bucket == NULL) {
        int index = size_to_index_freeing(size - sizeof(header_t));
        ASSERT(index >= 0);
        set_free_list_bit(heap, index);
        bucket = &heap->free_lists[index];
    }
    free_t *old_head = *bucket;
    if (old_head != NULL) old_head->prev = free_area;
    free_area->next = old_head;
    free_area->prev = NULL;
    *bucket = free_area;
    heap->free_blocks++;
    heap->remaining += size;
#ifdef CMPCT_DEBUG
    memset(free_area + 1, FREE_FILL, size - sizeof(free_t));
#endif
}

IRAM_ATTR static bool is_end_of_page_allocation(header_t *header)
{
    return get_size(header) == 0;
}

// Called with the lock.
IRAM_ATTR static void free_to_page_allocator(cmpct_heap_t *heap, header_t *header, size_t size)
{
    // Arena structure is immediately before the sentinel header.
    arena_t *arena = (arena_t *)header - 1;
    size += sizeof(*arena);

    // Unlink from doubly linked list.
    arena_t *next = arena->next;
    arena_t *previous = arena->previous;
    next->previous = previous;
    previous->next = next;

    DEBUG_ASSERT(IS_PAGE_ALIGNED(size));
    page_free(heap, arena, size >> PAGE_SIZE_SHIFT, /* for_malloc = */ true);
    // Adjust the heap->size.  Free pages are counted fully, but arenas
    // allocated on pages have the arena pointer and sentinels subtracted.
    heap->size += sizeof(arena_t) + 2 * sizeof(header_t);
}

IRAM_ATTR static void fix_left_size(header_t *right, header_t *new_left)
{
    int tag = get_left_size(right) & 1;
    set_left_size(right, (char *)right - (char *)new_left + tag);
}

IRAM_ATTR static void unlink_free(cmpct_heap_t *heap, free_t *free_area, int bucket)
{
    if (get_size(&free_area->header) >= (1 << HEAP_ALLOC_VIRTUAL_BITS)) FATAL("Invalid free");
    heap->remaining -= get_size(&free_area->header);
    heap->free_blocks--;
    ASSERT(heap->remaining < 4000000000u);
    ASSERT(heap->free_blocks < 4000000000u);
    ASSERT(bucket >= 0 && bucket < NUMBER_OF_BUCKETS);
    free_t *next = free_area->next;
    free_t *prev = free_area->prev;
    if (heap->free_lists[bucket] == free_area) {
        heap->free_lists[bucket] = next;
        if (next == NULL) clear_free_list_bit(heap, bucket);
    }
    if (prev != NULL) prev->next = next;
    if (next != NULL) next->prev = prev;
}

IRAM_ATTR static void unlink_free_unknown_bucket(cmpct_heap_t *heap, free_t *free_area)
{
    return unlink_free(heap, free_area, size_to_index_freeing(get_size(&free_area->header) - sizeof(header_t)));
}

// Called with the lock.
IRAM_ATTR static void free_memory(cmpct_heap_t *heap, header_t *header, size_t left_size, size_t size)
{
    create_free_area(heap, header, left_size, size, NULL);
    header_t *left = left_header(header);
    header_t *right = right_header(header);
    fix_left_size(right, header);
    // The alignment test is both for efficiency and to ensure that non-page
    // aligned areas that we give to the allocator are not returned to the page
    // allocator, which cannot handle them.
    if (IS_PAGE_ALIGNED((uintptr_t)left - sizeof(arena_t)) &&
        IS_PAGE_ALIGNED((uintptr_t)right + sizeof(header_t)) &&
        is_start_of_page_allocation(left) &&
        is_end_of_page_allocation(right)) {
        // A whole number of pages were free and can be returned to the page allocator.
        unlink_free_unknown_bucket(heap, (free_t *)header);
        free_to_page_allocator(heap, left, size + get_size(left) + sizeof(header_t));
    }
}

IRAM_ATTR static void *create_allocation_header(
    header_t *header, size_t size, size_t left_size, void *tag)
{
    set_left_size(header, untag(left_size));
    set_size(header, size);
    header->tag = tag;
    return header + 1;
}

IRAM_ATTR static int get_bucket_for_size(cmpct_heap_t *heap, size_t size, int start_bucket)
{
    int bucket = find_nonempty_bucket(heap, start_bucket);
    if (bucket == -1) {
        // Grow heap by a few pages. If we can.
        int pages_needed = ROUND_UP(size + ROUNDED_SMALL_ALLOCATION_LIMIT - SMALL_ALLOCATION_LIMIT, PAGE_SIZE) >> PAGE_SIZE_SHIFT;
        if (heap_grow(heap, NULL, pages_needed) < 0) {
            unlock(heap);
            return -1;
        }
        bucket = find_nonempty_bucket(heap, start_bucket);
        // Allocation is always less than one page so this must succeed.
        ASSERT(bucket >= 0 && bucket < NUMBER_OF_BUCKETS);
    }
    return bucket;
}

IRAM_ATTR void *cmpct_alloc(cmpct_heap_t *heap, size_t size)
{
    // In C++ we are not allowed to return null for zero length allocations, so
    // bump the size and return a small allocation instead.
    if (size == 0u) size = 1;

    ASSERT(size <= SMALL_ALLOCATION_LIMIT);

    size_t rounded_up;
    int start_bucket = size_to_index_allocating(size, &rounded_up);

    rounded_up += sizeof(header_t);

    lock(heap);

    int bucket = get_bucket_for_size(heap, size, start_bucket);
    if (bucket == -1) return NULL;

    free_t *head = heap->free_lists[bucket];
    return allocation_tail(heap, head, size, rounded_up, bucket);
}

// Takes a block on the free list, unlinks it, possibly creates a new freelist
// entry from the excess, and returns the newly allocated memory.  On entry the
// heap should be locked.  Unlocks the heap.
IRAM_ATTR static void *allocation_tail(cmpct_heap_t *heap, free_t *head, size_t size, size_t rounded_up, int bucket)
{
    header_t *block = &head->header;
    size_t block_size = get_size(block);
    size_t rest = block_size - rounded_up;
    // We can't carve off the rest for a new free space if it's smaller than
    // the free-list linked structure.  We also don't carve it off if it's less
    // than 3.2% the size of the allocation.  This is to avoid small long-lived
    // allocations being placed right next to large allocations, hindering
    // coalescing and returning pages to the OS.  Note that the buckets already
    // cause allocations to be rounded up to the nearest bucket size.  The
    // buckets are spaced in intervals that are between 6% and 12% apart.
    if (rest >= sizeof(free_t) && rest > (size >> 5)) {
        header_t *right = right_header(block);
        unlink_free(heap, head, bucket);
        header_t *free = (header_t *)((char *)head + rounded_up);
        create_free_area(heap, free, rounded_up, rest, NULL);
        fix_left_size(right, free);
        block_size -= rest;
    } else {
        unlink_free(heap, head, bucket);
    }
    void *tag = GET_THREAD_LOCAL_TAG;
    void *result =
        create_allocation_header(block, block_size, get_left_size(block), tag);
    heap->allocated_blocks++;
    for (int i = 0; i < rounded_up - sizeof(header_t); i += sizeof(int)) {
        ((int *)(result))[i >> 2] = 0;
    }
#ifdef CMPCT_DEBUG
    memset(result, ALLOC_FILL, size);
    memset(((char *)result) + size, PADDING_FILL, (rounded_up - size) - sizeof(header_t));
#endif
    unlock(heap);
    return result;
}

IRAM_ATTR void cmpct_free_optionally_locked(cmpct_heap_t *heap, void *payload, bool use_locking)
{
    if (payload == NULL) return;
    if (heap->ignore_free) return;
    header_t *header = (header_t *)payload - 1;
    if (is_tagged_as_free(header)) FATAL("Invalid free");
    size_t size = get_size(header);
    if (use_locking) lock(heap);
    heap->allocated_blocks--;
    header_t *left = left_header(header);
    header_t *right = right_header(header);
    if (is_tagged_as_free(left)) {
        // Place a free marker in the middle of the coalesced free area in
        // order to catch more double frees.
        set_left_size(header, tag_as_free(get_left_size(header)));
        // Coalesce with left free object.
        unlink_free_unknown_bucket(heap, (free_t *)left);
        if (is_tagged_as_free(right)) {
            // Coalesce both sides.
            unlink_free_unknown_bucket(heap, (free_t *)right);
            free_memory(heap, left, get_left_size(left), get_size(left) + size + get_size(right));
        } else {
            // Coalesce only left.
            free_memory(heap, left, get_left_size(left), get_size(left) + size);
        }
    } else {
        if (is_tagged_as_free(right)) {
            // Coalesce only right.
            unlink_free_unknown_bucket(heap, (free_t *)right);
            free_memory(heap, header, get_left_size(header), size + get_size(right));
        } else {
            free_memory(heap, header, get_left_size(header), size);
        }
    }
    if (use_locking) unlock(heap);
}

IRAM_ATTR void cmpct_free(cmpct_heap_t *heap, void *payload)
{
    cmpct_free_optionally_locked(heap, payload, true);
}

INLINE void cmpct_free_already_locked(cmpct_heap_t *heap, void *payload)
{
    cmpct_free_optionally_locked(heap, payload, false);
}

// Get the rounded-up size of an allocation on the cmpct heap, given the
// address.  Can be called without the lock.
IRAM_ATTR static size_t allocation_size(void *payload)
{
    header_t *header = (header_t *)payload - 1;
    size_t size = get_size(header) - sizeof(header_t);
    return size;
}

// Set the accounting tag of an existing allocation.
IRAM_ATTR static void set_tag(void *payload, void *tag)
{
    header_t *header = (header_t *)payload - 1;
    header->tag = tag;
}

// Each allocation area has an arena structure at the start to link them
// together and a sentinel at either end that is the size of one header.
static const size_t arena_overhead = 2 * sizeof(header_t) + sizeof(arena_t);

// Adds an arena for small allocations to the heap.
IRAM_ATTR static void add_to_heap(cmpct_heap_t *heap, void *new_area, size_t size, free_t **bucket)
{
    ASSERT(size < 32 * 1024);  // We use 16 bit offsets within arenas.
    void *top = (char *)new_area + size;
    arena_t *new_arena = (arena_t *)new_area;
    // Link into doubly linked list.
    arena_t *old_next = heap->arenas.next;
    new_arena->next = old_next;
    new_arena->previous = &heap->arenas;
    heap->arenas.next = new_arena;
    old_next->previous = new_arena;

    header_t *left_sentinel = (header_t *)(new_arena + 1);
    // Not free, stops attempts to coalesce left.
    create_allocation_header(left_sentinel, sizeof(header_t), 0, NULL);
    header_t *new_header = left_sentinel + 1;
    size_t free_size = size - arena_overhead;
    heap->size += free_size;
    create_free_area(heap, new_header, sizeof(header_t), free_size, bucket);
    header_t *right_sentinel = (header_t *)(top - sizeof(header_t));
    // Not free, stops attempts to coalesce right.
    create_allocation_header(right_sentinel, 0, free_size, NULL);
}

// Grab n pages of memory from the page allocator.
// Called with the lock, apart from during init.
IRAM_ATTR static ssize_t heap_grow(cmpct_heap_t *heap, free_t **bucket, int pages)
{
    // Allocate more pages.  The allocation tag is a pointer to the heap
    // itself so that it won't match any allocation tag used by the program.
    void *ptr = page_alloc(heap, pages, PAGE_SIZE, NULL, /* for_malloc = */ true);
    if (ptr == NULL) return -1;
    LTRACEF("growing heap by 0x%x bytes, new ptr %p\n", pages << PAGE_SIZE_SHIFT, ptr);
    // Add_to_heap will increase size.  That's often OK when we are adding
    // non-page-sized areas to the heap, but that's not appropriate here
    // because the pages were already part of the heap.
    heap->size -= pages * PAGE_SIZE;
    add_to_heap(heap, ptr, pages * PAGE_SIZE, bucket);
    return pages * PAGE_SIZE;
}

void cmpct_init(cmpct_heap_t *heap)
{
    LTRACE_ENTRY;

    // Initialize the free list.  The heap structure can reside in
    // IRAM, so it is important to avoid byte stores here.  We've
    // seen cases where the compiler cleverly optimizes tight loops,
    // turning word stores into byte stores.  When passed properly
    // aligned addresses and sizes, the memset implementation is
    // guaranteed to only use word stores, so we use that.
    memset(heap->free_lists, 0, sizeof(heap->free_lists));
    memset(heap->free_list_bits, 0, sizeof(heap->free_list_bits));

    heap->lock = NULL;
    heap->ignore_free = NULL;
    heap->size = heap->number_of_pages * PAGE_SIZE;
    heap->remaining = heap->size;
    heap->free_blocks = 1;  // All the free pages make up one free block.
    heap->allocated_blocks = 0;
    // Empty doubly linked list points to itself.
    heap->arenas.previous = &heap->arenas;
    heap->arenas.next = &heap->arenas;
}

// Takes a memory area for a heap.  The first part of the memory that was given
// is used for an instance of cmpct_heap_t with the bookkeeping information for
// the heap.  The whole pages are added to the page allocator for this heap.
// Space that is not page-aligned is put on the freelist.  It will never be
// returned to the page allocator because only page aligned free entries trigger
// the code that detects wholly empty pages and returns them to the page allocator.
cmpct_heap_t *cmpct_register_impl(void *start, size_t size)
{
    if (size < sizeof(cmpct_heap_t) + sizeof(header_t)) return NULL;  // Area too small.
    // We can't have more pages than the rounded down size so
    // this does an optimistic calculation of the number pages.
    intptr_t pages = size >> PAGE_SIZE_SHIFT;
    ASSERT(pages >= 0);

    uintptr_t start_int = (uintptr_t)start;
    intptr_t header_waste = ROUND_UP(start_int, sizeof(header_t)) - start_int;
    uintptr_t end_int = (uintptr_t)start + size;
    start_int += header_waste;
    uintptr_t end_of_struct = ROUND_UP(start_int + sizeof(cmpct_heap_t) + pages * sizeof(Page), sizeof(header_t));
    ASSERT(end_of_struct <= end_int);
    uintptr_t start_of_first_page = ROUND_UP(end_of_struct, PAGE_SIZE);

    // May be a little smaller than the old value of pages because the array of
    // struct Pages goes into what we thought would the first page(s).
    pages = start_of_first_page > end_int ? 0 : (end_int - start_of_first_page) >> PAGE_SIZE_SHIFT;

    cmpct_heap_t *page_heap = (cmpct_heap_t *)start_int;
    page_heap->end_of_heap_structure = (void *)end_of_struct;
    page_heap->number_of_pages = pages;
    page_heap->page_base = (char *)start_of_first_page;
    for (size_t i = 0; i < pages; i++) {
        page_heap->pages[i].status = PAGE_FREE;
        page_heap->pages[i].tag = NULL;
    }
    // A sentinel page is in_use, but not a continuation of any previous
    // allocation.  This is just in the index, we don't actually waste a page
    // on this.
    page_heap->pages[pages].status = PAGE_IN_USE;
    page_heap->pages[pages].tag = NULL;

    page_heap->highest_address = (void *)end_int;

    cmpct_init(page_heap);

    // If we were handed a very small amount of memory then we just give the
    // entire space to the small allocation arena.
    if (start_of_first_page >= end_int) {
        intptr_t rest = ROUND_DOWN(end_int, sizeof(header_t)) - end_of_struct;
        if (rest >= (intptr_t)(arena_overhead + sizeof(free_t))) {
            add_to_heap(page_heap, (void *)end_of_struct, rest, NULL);
        }
    } else {
        // Unaligned memory before the start of the first page is added to the
        // heap for small allocations.
        intptr_t rest = start_of_first_page - end_of_struct;
        if (rest > (intptr_t)(arena_overhead + sizeof(free_t))) {
            add_to_heap(page_heap, (void *)end_of_struct, rest, NULL);
        }
        // Unaligned memory after the end of the last page can also be added to
        // the heap for small allocations.
        size_t end_of_last_page = start_of_first_page + PAGE_SIZE * pages;
        rest = ROUND_DOWN(end_int, sizeof(header_t)) - end_of_last_page;
        if (rest > (intptr_t)(arena_overhead + sizeof(free_t))) {
            add_to_heap(page_heap, (void *)end_of_last_page, rest, NULL);
        }
    }
    return page_heap;
}

IRAM_ATTR void *cmpct_malloc_impl(cmpct_heap_t *heap, size_t size)
{
    // Allocations smaller than 0.75 pages or between one page and 1.5 pages
    // are allocated using the bucket allocator from a larger area.  Everything
    // else is rounded up to a page size and taken from the page allocator.
    // (It is important for correctness that 0 length allocations don't go to
    // the page allocator.)
    const size_t ALMOST_FULL_PAGE = PAGE_SIZE / 4 * 3;
    const size_t PAGE_AND_A_HALF = PAGE_SIZE / 2 * 3;
    ASSERT(PAGE_AND_A_HALF <= SMALL_ALLOCATION_LIMIT);
    if (size < ALMOST_FULL_PAGE ||
        (PAGE_SIZE < size && size <= PAGE_AND_A_HALF)) {
      return cmpct_alloc(heap, size);
    }
    // Size is (almost) a multiple of page size or just big.
    lock(heap);
    void *tag = GET_THREAD_LOCAL_TAG;
    void *result = page_alloc(heap, PAGES_FOR_BYTES(size), PAGE_SIZE, tag, /* for_malloc = */ false);
    unlock(heap);
    return result;
}

IRAM_ATTR void *cmpct_aligned_alloc_impl(cmpct_heap_t *heap, size_t size, size_t alignment) {
    // Only allow powers of 2 as alignments.
    if (((alignment - 1) & alignment) != 0) return NULL;

    // The page allocator already has the ability to return allocations that
    // are more aligned than the page size.
    if (alignment >= PAGE_SIZE / 2) {
        // We take 2k (half-page) allocations in here too, because treating them as
        // page allocations will waste 2k, but putting them in the normal system
        // actually wastes even more.
        lock(heap);
        void *tag = GET_THREAD_LOCAL_TAG;
        void *result = page_alloc(heap, PAGES_FOR_BYTES(size), alignment, tag, /* for_malloc = */ false);
        unlock(heap);
        return result;
    }

    if (alignment <= NATURAL_ALIGNMENT) return cmpct_malloc_impl(heap, size);

    size = ROUND_UP(size, NATURAL_ALIGNMENT);

    // Our approach to aligned allocations requires us to temporarily create a
    // free space of the required size, so there's a minimum size below which
    // it doesn't work.
    if (size < sizeof(free_t)) size = sizeof(free_t);

    // This gives us at least one alignment of slack to position the returned
    // pointer, plus space for the header.  Worst case looking from the back of
    // the allocation is that there almost an alignment-worth of waste at the
    // end, the allocation requested, then an allocation header,
    // sizeof(header_t), then a free list entry, sizeof(free_t).
    size_t aligned_size = size + alignment - NATURAL_ALIGNMENT + sizeof(header_t) + sizeof(free_t);

    size_t unused;
    int start_bucket = size_to_index_allocating(aligned_size, &unused);

    lock(heap);

    int bucket = get_bucket_for_size(heap, aligned_size, start_bucket);
    if (bucket == -1) return NULL;  // Out of memory.

    free_t *head = heap->free_lists[bucket];
    header_t *block = &head->header;
    uintptr_t first_possible_location = (uintptr_t)(block + 1);
    uintptr_t location = ROUND_UP(first_possible_location, alignment);
    size_t size_with_header = size + sizeof(header_t);
    if (location == first_possible_location) {
        // Luckily already aligned.
        return allocation_tail(heap, head, size, size_with_header, bucket);
    }
    while (location - first_possible_location < sizeof(free_t)) {
        // No space for the free list header.
        location += alignment;
    }
    // We are splitting a free block into an unneeded part on the left and an
    // aligned part.
    header_t *right = right_header(block);
    unlink_free(heap, head, bucket);
    size_t unneeded_free_size = location - first_possible_location;
    size_t aligned_part_size = get_size(block) - unneeded_free_size;
    create_free_area(heap, head, get_left_size(block), unneeded_free_size, NULL);
    header_t *aligned_header = (header_t *)location - 1;
    // Note: This is the only moment where there are two free areas adjacent to
    // each other.  Normally we coalesce agressively.
    create_free_area(heap, aligned_header, unneeded_free_size, aligned_part_size, NULL);
    fix_left_size(right, aligned_header);

    // Create the allocation from the aligned area, possibly freeing the excess
    // on the right.
    return allocation_tail(heap, (free_t *)aligned_header, size, size_with_header, size_to_index_freeing(aligned_part_size - sizeof(header_t)));
}

IRAM_ATTR static bool is_page_allocated(cmpct_heap_t *heap, void *p)
{
    if (p == NULL || ((size_t)p & (PAGE_SIZE - 1)) != 0) return false;
    // The pointer is page-aligned, so it might be a page-allocation, or it
    // could just be a normal allocation in the middle of a multi-page arena
    // that happens to be aligned.
    size_t page = page_number(heap, p);
    // Only the first page in a multi-page allocation is marked as PAGE_IN_USE.
    // The others are marked as PAGE_CONTINUED.
    int status = heap->pages[page].status;
    if (status == PAGE_FREE) FATAL("Invalid free");
    return status == PAGE_IN_USE;
}

IRAM_ATTR void cmpct_free_impl(cmpct_heap_t *heap, void *p)
{
    if (is_page_allocated(heap, p)) {
        lock(heap);
        page_free(heap, p, 0, /* for_malloc = */ false);
        unlock(heap);
    } else {
        cmpct_free(heap, p);
    }
}

// Get the page number of a page-aligned pointer in the current heap.  Called
// with the lock.
IRAM_ATTR static size_t page_number(cmpct_heap_t *heap, void *p)
{
    size_t offset = (char *)p - heap->page_base;
    size_t page = offset >> PAGE_SIZE_SHIFT;
    return page;
}

/* Can be called without the lock. */
IRAM_ATTR size_t cmpct_get_allocated_size_impl(cmpct_heap_t *heap, void *p)
{
    if (p == NULL) return 0;
    if (!is_page_allocated(heap, p)) {
        size_t size = allocation_size(p);
        return size;
    }
    size_t page = page_number(heap, p);
    for (size_t i = 1; true; i++) {
        /* The pages always end with a dummy allocated page.
           Since we don't necessarily have the lock the status of the
           one-past-the-end page may change between PAGE_FREE,
           PAGE_IN_USE, and PAGE_IN_USE_FOR_MALLOCS, but all will
           give the same result here.  */
        if (heap->pages[page + i].status != PAGE_CONTINUED) return i << PAGE_SIZE_SHIFT;
    }
}

/* Effectuates a page-based realloc when we have found an overlapping new area
   big enough for the allocation.
   Called with the lock.  */
IRAM_ATTR static void *page_grow_allocation(cmpct_heap_t *heap, void *p, size_t old_page, size_t old_pages, size_t new_page, size_t new_pages) {
    heap->pages[new_page].status = PAGE_IN_USE;
    for (size_t j = new_page + 1; j < new_page + new_pages; j++) {
        heap->pages[j].status = PAGE_CONTINUED;
    }
    /* Adjust the heap accounting for number of contiguous blocks.  */
    if (new_page != old_page &&
        (new_page == 0 || heap->pages[new_page - 1].status != PAGE_FREE)) {
        heap->free_blocks--;
    }
    if (new_page + new_pages != old_page + old_pages &&
        heap->pages[new_page + new_pages].status != PAGE_FREE) {
        heap->free_blocks--;
    }
    heap->remaining -= (new_pages - old_pages) << PAGE_SIZE_SHIFT;
    /* Move the data to the new location.  */
    size_t distance = (old_page - new_page) << PAGE_SIZE_SHIFT;
    if (distance == 0) return p;
    uint8_t *destination = (uint8_t *)p - distance;
    memmove(destination, p, old_pages << PAGE_SIZE_SHIFT);
    return destination;
}

/* Attempts to grow the current page-based allocation into adjacent pages
   or shrink the current page-based allocation without moving data.
   Called with the lock.  */
IRAM_ATTR static void *realloc_page_allocation_helper(cmpct_heap_t *heap, void *p, size_t size, size_t old_size)
{
    size_t new_pages = ROUND_UP(size, PAGE_SIZE) >> PAGE_SIZE_SHIFT;
    size_t old_pages = old_size >> PAGE_SIZE_SHIFT;
    if (new_pages == old_pages) return p;
    size_t page = page_number(heap, p);
    if (new_pages > old_pages) {
        /* Growing a page allocation. */
        for (size_t i = page + old_pages; i < page + new_pages; i++) {
            if (heap->pages[i].status != PAGE_FREE) {
                /* Failed to grow only forwards - can we grow backwards? */
                if (i < new_pages) return NULL;
                size_t first_page = i - new_pages;
                for (size_t j = first_page; j < page; j++) {
                    if (heap->pages[j].status != PAGE_FREE) {
                        return NULL;
                    }
                }
                return page_grow_allocation(heap, p, page, old_pages, first_page, new_pages);
            }
        }
        return page_grow_allocation(heap, p, page, old_pages, page, new_pages);
    } else {
        /* Shrinking a page allocation. */
        for (size_t i = page + new_pages; i < page + old_pages; i++) {
            heap->pages[i].status = PAGE_FREE;
        }
        if (heap->pages[page + old_pages].status != PAGE_FREE) {
            heap->free_blocks++;
        }
        heap->remaining += (old_pages - new_pages) << PAGE_SIZE_SHIFT;
        return p;
    }
}

/* Attempts to grow the current page-based allocation into adjacent pages
   or shrink the current page-based allocation without moving data.
   Called with the lock.  */
IRAM_ATTR static void *realloc_page_allocation(cmpct_heap_t *heap, void *p, size_t size, size_t old_size)
{
    void *result = realloc_page_allocation_helper(heap, p, size, old_size);
    if (result == NULL) return NULL;
    // On a successful realloc, set the accounting tag to the current value.
    void *tag = GET_THREAD_LOCAL_TAG;
    heap->pages[page_number(heap, p)].tag = tag;
    return result;
}

/* This realloc implementation always first tries to create a new allocation
   and copy the data.  There are so few chances to defragment a malloc heap
   that we will try to move the data when we can.

   If this fails we may just return the original area if the size is close
   enough.

   For large (page-based) failing reallocations we attempt a new allocation
   that overlaps with the old one.

   A successful realloc will always set the accounting tag of the allocation,
   regardless of whether the allocation is actually moved.
   */
IRAM_ATTR void *cmpct_realloc_impl(cmpct_heap_t *heap, void *p, size_t size)
{
    if (!size) {
        cmpct_free_impl(heap, p);
        /* C++ "new" does not like null responses for zero-length allocations,
           but it never calls realloc so we can get away with it here.  */
        return NULL;
    }
    void *new_allocation = cmpct_malloc_impl(heap, size);
    if (!p) return new_allocation;
    size_t old_size = cmpct_get_allocated_size_impl(heap, p);
    if (new_allocation) {
        memcpy(new_allocation, p, MIN(old_size, size));
        cmpct_free_impl(heap, p);
        return new_allocation;
    }
    // New allocation failed.
    if (is_page_allocated(heap, p)) {
        lock(heap);
        // Although the new allocation failed we may be able to shrink or grow
        // the original page-based allocation.
        void *result = realloc_page_allocation(heap, p, size, old_size);
        unlock(heap);
        return result;
    } else {
        /* We know the old area was not page allocated, which puts an
           upper bound on how large it could be.  Therefore it can't
           overflow the calculation below.  */
        if (size <= old_size && size + sizeof(free_t) > (old_size * 4) / 3) {
            /* We are already in roughly the correct bucket, do nothing.
               Since the old_size is often larger than the original requested
               allocation we may hit this case even when growing the
               allocation.  */
            set_tag(p, GET_THREAD_LOCAL_TAG);
            return p;
        }
        return NULL;
    }
}

size_t cmpct_free_size_impl(cmpct_heap_t *heap)
{
    return heap->remaining;
}

void cmpct_get_info_impl(cmpct_heap_t *heap, multi_heap_info_t *info)
{
    lock(heap);

    info->total_free_bytes = heap->remaining;
    // total_allocated_bytes includes the headers on each allocation, but
    // doesn't include the static structures that are always there once
    // the heap has been set up.  This means it doesn't include the arena
    // structures and the sentinels at each end of each arena.
    info->total_allocated_bytes = heap->size - heap->remaining;
    info->largest_free_block = 0;
    // TODO: We don't currently keep track of the all-time low number of free
    // bytes.
    info->minimum_free_bytes = 0;
    info->allocated_blocks = heap->allocated_blocks;
    info->free_blocks = heap->free_blocks;
    size_t current_page_run = 0;
    page_use_t current_status = PAGE_FREE;
    bool current_page_run_is_a_single_allocation = false;
    // Include sentinel in iteration.
    for (size_t i = 0; i <= heap->number_of_pages; i++) {
        Page *page = &heap->pages[i];
        if (page->status == current_status && i != heap->number_of_pages) {
            current_page_run += PAGE_SIZE;
        } else {
            if (current_status == PAGE_FREE) {
                if (current_page_run != 0) {
                    info->free_blocks++;
                    if (current_page_run > info->largest_free_block) {
                        info->largest_free_block = current_page_run;
                    }
                }
            } else {
                ASSERT(current_status == PAGE_CONTINUED);
                if (current_page_run_is_a_single_allocation) {
                    if (current_page_run != 0) info->allocated_blocks++;
                }
            }
            if (page->status == PAGE_FREE) {
                current_status = PAGE_FREE;
            } else {
                // When we move from one allocation to the next the first page
                // in the new allocation is in use or free (never continued).
                ASSERT(page->status == PAGE_IN_USE ||
                       page->status == PAGE_IN_USE_FOR_MALLOCS);
                // Subsequent pages in the same allocation will be marked as
                // continued, so set us up to expect that.
                current_status = PAGE_CONTINUED;
                current_page_run_is_a_single_allocation = page->status == PAGE_IN_USE;
            }
            current_page_run = PAGE_SIZE;
        }
    }
    if (info->largest_free_block == 0) {
        // All pages are taken so largest free block is in the cmpctmalloc-
        // controlled area.
        for (int i = BUCKET_WORDS * 32 - 1; i >= 0; i--) {
            if (find_nonempty_bucket(heap, i) != -1) {
                free_t *head = heap->free_lists[i];
                size_t size = get_size(&head->header) - sizeof(header_t);
                if (size <= 128) {
                    // These buckets are precise.
                    info->largest_free_block = size;
                } else {
                    // For larger sizes the bucket sizes are approximate, so
                    // round down by 1/8th to get a size we are guaranteed to
                    // be able to deliver.
                    info->largest_free_block = (size_t)(size * 0.87499) & ~7l;
                }
                break;
            }
        }
    }
    info->total_blocks = info->free_blocks + info->allocated_blocks;
    // The implementation always takes the first part of its area for admin, so
    // it can never return an address that is lower than the end of that.
    info->lowest_address = heap->end_of_heap_structure;
    info->highest_address = heap->highest_address;
    unlock(heap);
}

size_t cmpct_minimum_free_size_impl(cmpct_heap_t *heap)
{
    multi_heap_info_t info;
    cmpct_get_info_impl(heap, &info);
    return info.minimum_free_bytes;
}

// Called with the lock.
IRAM_ATTR static void *page_alloc(cmpct_heap_t *heap, intptr_t pages, uintptr_t alignment, void *tag, bool for_malloc)
{
    // If pages == 0, then we assume that the caller ran into an integer
    // overflow. This can happen if PAGES_FOR_BYTES was used on
    // a really big size.
    if (pages == 0) return NULL;
    for (int i = 0; i <= heap->number_of_pages - pages; i++) {
        uintptr_t start_address = (uintptr_t)(heap->page_base + i * PAGE_SIZE);
        if (heap->pages[i].status == PAGE_FREE && (start_address & (alignment - 1)) == 0) {
            bool big_enough = true;
            for (int j = 1; j < pages; j++) {
                if (heap->pages[i + j].status != PAGE_FREE) {
                    big_enough = false;
                    i += j;
                    break;
                }
            }
            if (big_enough) {
                heap->pages[i].status = for_malloc ? PAGE_IN_USE_FOR_MALLOCS : PAGE_IN_USE;
                heap->pages[i].tag = tag;
                for (int j = 1; j < pages; j++) {
                    heap->pages[i + j].status = PAGE_CONTINUED;
                }
                void *result = heap->page_base + i * PAGE_SIZE;
                for (int i = 0; i < pages << PAGE_SIZE_SHIFT; i += sizeof(int)) {
                    ((int *)(result))[i >> 2] = 0;
                }
                if (heap->pages[i + pages].status != PAGE_FREE) {
                  // We used up a whole contiguous sequence of free pages so
                  // this reduced the number of free blocks.
                  heap->free_blocks--;
                }
                // If the pages are being allocated for an arena for small
                // allocations then most of this reduction in heap->remaining
                // will be re-added in create_free_area.
                heap->remaining -= pages * PAGE_SIZE;
                return heap->page_base + i * PAGE_SIZE;
            }
        }
    }
    return NULL;
}

IRAM_ATTR static void page_iterate(cmpct_heap_t *heap, void *user_data, void *tag, tagged_memory_callback_t callback, int flags)
{
    for (int i = 0; i < heap->number_of_pages; i++) {
        int status = heap->pages[i].status;
        if (status != PAGE_CONTINUED) {
            // A flag can indicate that we should iterate over all allocations, but we still
            // don't iterate over the page allocations that the sub-page allocator made.
            bool iterate_free = false;
            bool iterate_allocated = false;
            int continuation_status = 0;
            void *found_tag = NULL;
            if (status == PAGE_FREE && (flags & CMPCTMALLOC_ITERATE_UNUSED) != 0) {
                iterate_free = true;
                continuation_status = PAGE_FREE;  // It's all one area as long as we see free pages.
                found_tag = (void *)CMPCTMALLOC_ITERATE_TAG_FREE;
            }
            if (status == PAGE_IN_USE &&
                (heap->pages[i].tag == tag ||
                 (flags & CMPCTMALLOC_ITERATE_ALL_ALLOCATIONS) != 0)) {
                iterate_allocated = true;
                continuation_status = PAGE_CONTINUED;  // It's all one area as long as we see continued pages.
                found_tag = heap->pages[i].tag;
            }
            if (iterate_free || iterate_allocated) {
                for (int j = 1; true; j++) {
                    ASSERT(i + j <= heap->number_of_pages);
                    if (heap->pages[i + j].status != continuation_status) {
                        void *allocation = heap->page_base + i * PAGE_SIZE;
                        if (callback(user_data, found_tag, allocation, j * PAGE_SIZE) && iterate_allocated) {
                            // Callback indicates we should free the memory.
                            page_free(heap, allocation, j, /* for_malloc = */ false);
                        }
                        i += j - 1;
                        break;
                    }
                }
            }
        }
    }
}

// Frees a number of pages allocated in one chunk.  This version of cmpctmalloc
// does not contain support for trimming a region obtained from the page
// allocator, so the number of pages is always the number of pages allocated,
// and we ignore the page count argument.  Called with the lock.
IRAM_ATTR static void page_free(cmpct_heap_t *heap, void *address, int page_count_unused, bool for_malloc)
{
    size_t page = page_number(heap, address);
    bool previous_is_free = page != 0 && heap->pages[page - 1].status == PAGE_FREE;
    int expected_status = for_malloc ? PAGE_IN_USE_FOR_MALLOCS : PAGE_IN_USE;
    if (page >= heap->number_of_pages || heap->pages[page].status != expected_status) {
        FATAL("Invalid free");
    }
    int pages_freed = 1;
    for (intptr_t j = page + 1; heap->pages[j].status == PAGE_CONTINUED; j++) {
        heap->pages[j].status = PAGE_FREE;
        pages_freed = j + 1 - page;
    }
    heap->remaining += pages_freed * PAGE_SIZE;
    bool next_is_free = heap->pages[page + pages_freed].status == PAGE_FREE;
    if (!previous_is_free && !next_is_free) {
      heap->free_blocks++;
    } else if (previous_is_free && next_is_free) {
      heap->free_blocks--;
    }
    heap->pages[page].status = PAGE_FREE;
}

void cmpct_set_lock_impl(cmpct_heap_t *heap, void *lock)
{
    heap->lock = lock;
}

void cmpct_internal_lock_impl(cmpct_heap_t *heap, void *lock)
{
    // No-op: locking is handled at the MULTI_HEAP_LOCK level using
    // vTaskSuspendAll/xTaskResumeAll.
}

void cmpct_internal_unlock_impl(cmpct_heap_t *heap, void *lock)
{
    // No-op: unlocking is handled at the MULTI_HEAP_UNLOCK level using
    // vTaskSuspendAll/xTaskResumeAll.
}

void cmpct_set_option(cmpct_heap_t *heap, int option, void *value)
{
    if (option == MALLOC_OPTION_THREAD_TAG) {
        void *task = xTaskGetCurrentTaskHandle();
        // First try to find an existing entry for this task.
        for (int i = 0; i < MAX_TAG_ENTRIES; i++) {
            if (tag_map[i].task == task) {
                tag_map[i].tag = value;
                return;
            }
        }
        // No existing entry found, use the first empty slot.
        for (int i = 0; i < MAX_TAG_ENTRIES; i++) {
            if (tag_map[i].task == NULL) {
                tag_map[i].task = task;
                tag_map[i].tag = value;
                return;
            }
        }
        // Tag map is full -- silently drop.
    } else if (option == MALLOC_OPTION_DISABLE_FREE) {
        heap->ignore_free = value;
    }
}

void *cmpct_get_option(int option)
{
    if (option != MALLOC_OPTION_THREAD_TAG) return NULL;
    void *task = xTaskGetCurrentTaskHandle();
    for (int i = 0; i < MAX_TAG_ENTRIES; i++) {
        if (tag_map[i].task == task) return tag_map[i].tag;
    }
    return NULL;
}

void cmpct_iterate_tagged_memory_areas(cmpct_heap_t *heap, void *user_data, void *tag, tagged_memory_callback_t callback, uint32_t flags)
{
    if ((flags & CMPCTMALLOC_ITERATE_UNLOCKED) == 0) {
        if (heap->lock == NULL) {
            // Might not be the earliest time we can test for the lock, but
            // it should still catch most cases.
            FATAL("Heap lock not set");
        }
        lock(heap);
    }
    bool iterate_heap_structure = (flags & CMPCTMALLOC_ITERATE_UNUSED) != 0;
    page_iterate(heap, user_data, tag, callback, flags);
    arena_t *end = &heap->arenas;
    header_t *to_free = NULL;
    for (arena_t *arena = heap->arenas.next; arena != end; arena = arena->next) {
        if ((flags & CMPCTMALLOC_ITERATE_UNUSED) != 0) {
            // The page starts with one arena and one sentinel header.
            uintptr_t first_possible_allocation = (uintptr_t)(arena + 1) + sizeof(header_t);
            // If this is the arena right after the heap structure, then do the
            // callback for the overhead of the heap structure itself at this
            // moment that the callback sees it while expecting callbacks for
            // the correct page.
            void *start_of_overhead;
            if (arena == heap->end_of_heap_structure) {
                start_of_overhead = heap;
                iterate_heap_structure = false;
            } else {
                start_of_overhead = arena;
            }
            callback(user_data, (void *)CMPCTMALLOC_ITERATE_TAG_HEAP_OVERHEAD, start_of_overhead, first_possible_allocation - (uintptr_t)start_of_overhead);
        }
        header_t *previous = (header_t *)(arena + 1);
        for (header_t *header = previous + 1; true; header = right_header(header)) {
            ASSERT(left_header(header) == previous);
            previous = header;
            if ((flags & CMPCTMALLOC_ITERATE_UNUSED) != 0) {
                callback(user_data, (void *)CMPCTMALLOC_ITERATE_TAG_HEAP_OVERHEAD, header, sizeof(header_t));
            }
            if (is_end_of_page_allocation(header)) break;
            if (is_tagged_as_free(header)) {
                if ((flags & CMPCTMALLOC_ITERATE_UNUSED) != 0) {
                    callback(user_data, (void *)CMPCTMALLOC_ITERATE_TAG_FREE, header + 1, get_size(header) - sizeof(header_t));
                }
            } else {
                if ((flags & CMPCTMALLOC_ITERATE_ALL_ALLOCATIONS) != 0 || header->tag == tag) {
                    if (callback(user_data, header->tag, header + 1, get_size(header) - sizeof(header_t))) {
                        // Callback returned true, so the allocation should be freed.
                        // We free with a delay so that it does not disturb the iteration.
                        if (to_free) {
                            cmpct_free_already_locked(heap, to_free + 1);
                        }
                        to_free = header;
                    }
                }
            }
        }
    }
    if (iterate_heap_structure) {
        callback(user_data, (void *)CMPCTMALLOC_ITERATE_TAG_HEAP_OVERHEAD, heap, (uintptr_t)heap->end_of_heap_structure - (uintptr_t)heap);
    }
    if (to_free) {
        cmpct_free_already_locked(heap, to_free + 1);
    }
    if ((flags & CMPCTMALLOC_ITERATE_UNLOCKED) == 0) {
        unlock(heap);
    }
}
