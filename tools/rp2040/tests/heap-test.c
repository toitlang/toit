// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "cmpctmalloc.h"

static int lock_depth;
static void *current_tag;
void cmpct_platform_lock(void) { lock_depth++; }
void cmpct_platform_unlock(void) { assert(lock_depth > 0); lock_depth--; }
void *cmpct_platform_get_tag(void) { return current_tag; }
void cmpct_platform_set_tag(void *tag) { current_tag = tag; }

static void *tagged_address;
static int find_tag(void *context, void *tag, void *address, size_t size) {
  (void)context; (void)tag;
  assert(tagged_address == NULL);
  assert(size == 8192);
  tagged_address = address;
  return 0;
}

static _Alignas(4096) unsigned char arena[264 * 1024];
struct allocation { unsigned char *data; size_t size; unsigned char byte; };
static uint32_t rng = 0x432a8765;
static uint32_t next(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static void check(struct allocation *a) {
  for (size_t i = 0; i < a->size; i++) assert(a->data[i] == a->byte);
}

static void exercise(size_t offset, size_t length) {
  memset(arena, 0xa5, sizeof(arena));
  cmpct_heap_t *heap = cmpct_register_impl(arena + offset, length);
  assert(heap);
  multi_heap_info_t initial;
  cmpct_get_info_impl(heap, &initial);
  assert(cmpct_malloc_impl(heap, SIZE_MAX) == NULL);
  assert(cmpct_aligned_alloc_impl(heap, SIZE_MAX, 4096) == NULL);
  assert(cmpct_aligned_alloc_impl(heap, 16, 0) == NULL);
  assert(cmpct_aligned_alloc_impl(heap, 16, 3) == NULL);
  for (size_t alignment = 1; alignment <= 16384; alignment *= 2) {
    void *zero = cmpct_aligned_alloc_impl(heap, 0, alignment);
    assert(zero && (uintptr_t)zero % alignment == 0);
    cmpct_free_impl(heap, zero);
  }
  struct allocation live[96] = {0};
  for (unsigned round = 0; round < 30000; round++) {
    struct allocation *a = &live[next() % 96];
    check(a);
    if (a->data && (next() & 3) == 0) {
      size_t size = next() % 40000 + 1;
      unsigned char *data = cmpct_realloc_impl(heap, a->data, size);
      if (data) {
        for (size_t i = 0; i < (size < a->size ? size : a->size); i++) assert(data[i] == a->byte);
        a->data = data; a->size = size;
        memset(data, a->byte, size);
      } else check(a);  // A failed realloc must retain the original data.
    } else {
      cmpct_free_impl(heap, a->data);
      a->data = NULL; a->size = 0;
      size_t size = next() % 7000;
      size_t alignment = (size_t)1 << (next() % 15);
      unsigned char *data = cmpct_aligned_alloc_impl(heap, size, alignment);
      if (data) {
        assert((uintptr_t)data % alignment == 0);
        assert(data >= arena + offset && data + size <= arena + offset + length);
        a->data = data; a->size = size; a->byte = (unsigned char)next();
        memset(data, a->byte, size);
      }
    }
    assert(lock_depth == 0);
    if ((round & 127) == 0) for (unsigned i = 0; i < 96; i++) check(&live[i]);
  }
  for (unsigned i = 0; i < 96; i++) { check(&live[i]); cmpct_free_impl(heap, live[i].data); }
  // Saturate page allocation, free alternating isolated pages, and reclaim
  // every one while the surrounding pages remain live. No alignment slack.
  void *pages[70]; size_t count = 0;
  while (count < 70 && (pages[count] = cmpct_aligned_alloc_impl(heap, 4096, 4096))) count++;
  assert(count >= length / 4096 - 2);
  for (size_t i = 0; i < count; i += 2) cmpct_free_impl(heap, pages[i]);
  for (size_t i = 0; i < count; i += 2) {
    pages[i] = cmpct_aligned_alloc_impl(heap, 4096, 4096);
    assert(pages[i] && (uintptr_t)pages[i] % 4096 == 0);
  }
  // Force realloc to grow backwards: no two free pages remain anywhere.
  assert(count > 3);
  cmpct_free_impl(heap, pages[1]);
  memset(pages[2], 0x52, 4096);
  current_tag = &current_tag;
  void *grown = cmpct_realloc_impl(heap, pages[2], 8192);
  assert(grown == pages[1]);
  for (size_t i = 0; i < 4096; i++) assert(((unsigned char *)grown)[i] == 0x52);
  tagged_address = NULL;
  cmpct_iterate_tagged_memory_areas(heap, NULL, current_tag, find_tag, 0);
  assert(tagged_address == grown);
  current_tag = NULL;
  cmpct_free_impl(heap, grown);
  pages[1] = pages[2] = NULL;
  for (size_t i = 0; i < count; i++) cmpct_free_impl(heap, pages[i]);
  multi_heap_info_t final;
  cmpct_get_info_impl(heap, &final);
  assert(initial.total_free_bytes == final.total_free_bytes);
  assert(final.total_allocated_bytes == 0);
  assert(lock_depth == 0);
  for (size_t i = 0; i < offset; i++) assert(arena[i] == 0xa5);
  for (size_t i = offset + length; i < sizeof(arena); i++) assert(arena[i] == 0xa5);
}

int main(void) {
  exercise(0, sizeof(arena));
  exercise(24, sizeof(arena) - 71);
  exercise(104, 65536);
  puts("Pico native allocator: PASS mixed allocations, realloc, exhaustion, isolated page reuse");
}
