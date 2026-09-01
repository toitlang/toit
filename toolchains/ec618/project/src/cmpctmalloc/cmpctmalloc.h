// Copyright (C) 2026 Toit contributors.

#pragma once

#include <stddef.h>
#include <stdint.h>

// Flags for heap iteration.  Coordinate with constants in the Toit VM.
#define CMPCTMALLOC_ITERATE_UNLOCKED 1
#define CMPCTMALLOC_ITERATE_ALL_ALLOCATIONS 2
#define CMPCTMALLOC_ITERATE_UNUSED   4

#define CMPCTMALLOC_ITERATE_TAG_FREE          (-1)  /// Memory is free and could be allocated.
#define CMPCTMALLOC_ITERATE_TAG_HEAP_OVERHEAD (-2)  /// Memory is used by malloc for internal accounting etc.

// Options for cmpct_set_option/cmpct_get_option.
#define MALLOC_OPTION_DISABLE_FREE 0
#define MALLOC_OPTION_THREAD_TAG 1

// Flags for cmpct_iterate_tagged_memory_areas.
// Use CMPCTMALLOC_ prefix to avoid clashing with top.h constants.
#define CMPCTMALLOC_ITERATE_ALL  2
#define CMPCTMALLOC_ITERATE_UNALLOC 4
#define CMPCTMALLOC_ITERATE_CUSTOM_TAGS 0x100

typedef struct multi_heap_info cmpct_heap_t;

typedef struct {
    size_t total_free_bytes;
    size_t total_allocated_bytes;
    size_t largest_free_block;
    size_t minimum_free_bytes;
    size_t allocated_blocks;
    size_t free_blocks;
    size_t total_blocks;
    void *lowest_address;
    void *highest_address;
} multi_heap_info_t;

typedef int (*tagged_memory_callback_t)(void *user_data, void *tag, void *allocation, size_t allocated_size);

cmpct_heap_t *cmpct_register_impl(void *start, size_t size);
void *cmpct_malloc_impl(cmpct_heap_t *heap, size_t size);
void cmpct_free_impl(cmpct_heap_t *heap, void *p);
void *cmpct_realloc_impl(cmpct_heap_t *heap, void *p, size_t size);
void *cmpct_aligned_alloc_impl(cmpct_heap_t *heap, size_t size, size_t alignment);
size_t cmpct_get_allocated_size_impl(cmpct_heap_t *heap, void *p);
void cmpct_get_info_impl(cmpct_heap_t *heap, multi_heap_info_t *info);
size_t cmpct_free_size_impl(cmpct_heap_t *heap);
size_t cmpct_minimum_free_size_impl(cmpct_heap_t *heap);
void cmpct_set_option(cmpct_heap_t *heap, int option, void *value);
void *cmpct_get_option(int option);
void cmpct_iterate_tagged_memory_areas(cmpct_heap_t *heap, void *user_data, void *tag, tagged_memory_callback_t callback, uint32_t flags);
