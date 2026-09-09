// Copyright (C) 2026 Toit contributors.
//
// FreeRTOS heap implementation #7: delegates to cmpctmalloc.
// This file provides the standard FreeRTOS heap symbols (pvPortMallocEC,
// vPortFree, etc.) and shadows heap_6.o in libfreertos.a at link time.

#include "FreeRTOS.h"
#include "task.h"
#include "portable.h"

// Always compiled for EC618 — shadows heap_6 at link time via
// --allow-multiple-definition. We can't use configSUPPORT_DYNAMIC_ALLOC_HEAP==7
// because the prebuilt libfreertos.a asserts it's 6.
#if 1

#include "cmpctmalloc.h"

// heap_stats_t and tagged_memory_callback_t are declared in portable.h.

#include <string.h>
#include <reent.h>

// Linker-defined symbols for the heap region.
extern char end_ap_data;
extern char start_up_buffer;

static cmpct_heap_t *heap = NULL;
static int heap_initialized = 0;

static void ensure_heap_initialized(void) {
    if (heap_initialized) return;
    heap_initialized = 1;
    void *start = (void *)&end_ap_data;
    size_t size = (size_t)(&start_up_buffer - &end_ap_data);
    heap = cmpct_register_impl(start, size);
}

// --- Standard FreeRTOS heap functions ---

void *pvPortMallocEC(size_t xWantedSize, unsigned int funcPtr) {
    (void)funcPtr;
    ensure_heap_initialized();
    return cmpct_malloc_impl(heap, xWantedSize);
}

void *pvPortReallocEC(void *pv, size_t xWantedSize, unsigned int funcPtr) {
    (void)funcPtr;
    ensure_heap_initialized();
    return cmpct_realloc_impl(heap, pv, xWantedSize);
}

void vPortFree(void *pv) {
    if (pv == NULL) return;
    ensure_heap_initialized();
    cmpct_free_impl(heap, pv);
}

void *pvPortZeroMalloc(size_t xWantedSize) {
    void *p = pvPortMallocEC(xWantedSize, 0);
    if (p) memset(p, 0, xWantedSize);
    return p;
}

void *pvPortAssertMalloc(size_t xWantedSize) {
    void *p = pvPortMallocEC(xWantedSize, 0);
    configASSERT(p);
    return p;
}

void *pvPortZeroAssertMalloc(size_t xWantedSize) {
    void *p = pvPortZeroMalloc(xWantedSize);
    configASSERT(p);
    return p;
}

void *pvPortMemalign(size_t alignment, size_t size) {
    ensure_heap_initialized();
    return cmpct_aligned_alloc_impl(heap, size, alignment);
}

void *pvPortMemAlignMallocEC(size_t xWantedSize, unsigned int funcPtr) {
    (void)funcPtr;
    return pvPortMemalign(8, xWantedSize);
}

size_t xPortGetFreeHeapSize(void) {
    if (!heap_initialized) return 0;
    return cmpct_free_size_impl(heap);
}

size_t xPortGetMinimumEverFreeHeapSize(void) {
    if (!heap_initialized) return 0;
    return cmpct_minimum_free_size_impl(heap);
}

size_t xPortGetTotalHeapSize(void) {
    return (size_t)(&start_up_buffer - &end_ap_data);
}

size_t xPortGetMaximumFreeBlockSize(void) {
    if (!heap_initialized) return 0;
    multi_heap_info_t info;
    cmpct_get_info_impl(heap, &info);
    return info.largest_free_block;
}

uint8_t xPortGetFreeHeapPct(void) {
    size_t total = xPortGetTotalHeapSize();
    if (total == 0) return 0;
    return (uint8_t)((xPortGetFreeHeapSize() * 100) / total);
}

uint8_t xPortIsFreeHeapOnAlert(void) {
    return xPortGetFreeHeapPct() < 10;
}

// --- Newlib reentrant wrappers (--wrap flags in linker) ---

void *__wrap__malloc_r(struct _reent *r, size_t size) {
    (void)r;
    return pvPortMallocEC(size, 0);
}

void __wrap__free_r(struct _reent *r, void *ptr) {
    (void)r;
    vPortFree(ptr);
}

void *__wrap__realloc_r(struct _reent *r, void *ptr, size_t size) {
    (void)r;
    return pvPortReallocEC(ptr, size, 0);
}

// newlib's _memalign_r over-allocates via _malloc_r and then tries to
// split the chunk by reading and rewriting a newlib-style chunk header.
// cmpctmalloc has no such header, so _memalign_r ends up reading garbage
// at the would-be header offset — sometimes a benign-looking pointer
// (silent heap corruption that bites later), sometimes an unmapped
// address (immediate bus fault). Route every caller — aligned_alloc,
// memalign, posix_memalign, valloc, pvalloc — at cmpct's aligned-alloc
// implementation instead.
void *__wrap__memalign_r(struct _reent *r, size_t alignment, size_t size) {
    (void)r;
    return pvPortMemalign(alignment, size);
}

// --- Toit-specific: heap stats and iteration ---

void vPortGetHeapStats(heap_stats_t *stats) {
    if (!heap_initialized) {
        memset(stats, 0, sizeof(*stats));
        return;
    }
    multi_heap_info_t info;
    cmpct_get_info_impl(heap, &info);
    stats->total_free_bytes = info.total_free_bytes;
    stats->total_allocated_bytes = info.total_allocated_bytes;
    stats->largest_free_block = info.largest_free_block;
    stats->minimum_free_bytes = info.minimum_free_bytes;
    stats->allocated_blocks = info.allocated_blocks;
    stats->free_blocks = info.free_blocks;
    stats->total_blocks = info.total_blocks;
    stats->lowest_address = info.lowest_address;
    stats->highest_address = info.highest_address;
}

void vPortIterateAllocations(void *user_data, void *tag,
    tagged_memory_callback_t callback, uint32_t flags) {
    if (!heap_initialized) return;
    cmpct_iterate_tagged_memory_areas(heap, user_data, tag, callback, flags);
}

void vPortSetHeapTag(void *tag) {
    if (!heap_initialized) return;
    cmpct_set_option(heap, MALLOC_OPTION_THREAD_TAG, tag);
}

void *vPortGetHeapTag(void) {
    return cmpct_get_option(MALLOC_OPTION_THREAD_TAG);
}

// Note: malloc/free/calloc/realloc are NOT overridden here.
// The CMSIS-RTOS2 layer (cmsis_os2.o in libfreertos.a) already provides
// these, and the --wrap flags handle the newlib _malloc_r/_free_r wrappers.

#endif
