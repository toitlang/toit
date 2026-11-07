// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
// One heap for the VM, FreeRTOS and libc, including newlib's reentrant calls.
#include <errno.h>
#include <malloc.h>
#include <reent.h>
#include <stdint.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "pico/platform.h"
#include "heap_rp2040.h"

extern char end;
extern char __StackLimit;
static cmpct_heap_t *heap;
static size_t capacity;

void cmpct_platform_lock(void) {
  configASSERT(__get_current_exception() == 0);
  if (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) vTaskSuspendAll();
}
void cmpct_platform_unlock(void) {
  if (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) xTaskResumeAll();
}
void *cmpct_platform_get_tag(void) {
  if (xTaskGetCurrentTaskHandle() == NULL) return NULL;
  return pvTaskGetThreadLocalStoragePointer(NULL, 1);
}
void cmpct_platform_set_tag(void *tag) {
  if (xTaskGetCurrentTaskHandle() != NULL) vTaskSetThreadLocalStoragePointer(NULL, 1, tag);
}

static void ensure_heap(void) {
  cmpct_platform_lock();
  if (heap == NULL) {
    uintptr_t first = ((uintptr_t)&end + 7) & ~(uintptr_t)7;
    capacity = (uintptr_t)&__StackLimit - first;
    heap = cmpct_register_impl((void *)first, capacity);
    configASSERT(heap != NULL);
  }
  cmpct_platform_unlock();
}

void *malloc(size_t size) {
  ensure_heap();
  // Bound sizes before the allocator's page rounding and signed arithmetic.
  if (size > capacity) { errno = ENOMEM; return NULL; }
  void *result = cmpct_malloc_impl(heap, size);
  if (result == NULL) errno = ENOMEM;
  return result;
}
void free(void *pointer) {
  if (pointer == NULL) return;
  ensure_heap();
  cmpct_free_impl(heap, pointer);
}
void *calloc(size_t count, size_t size) {
  if (size != 0 && count > SIZE_MAX / size) { errno = ENOMEM; return NULL; }
  size_t bytes = count * size;
  void *result = malloc(bytes);
  if (result != NULL) memset(result, 0, bytes);
  return result;
}
void *realloc(void *pointer, size_t size) {
  ensure_heap();
  if (size > capacity) { errno = ENOMEM; return NULL; }
  void *result = cmpct_realloc_impl(heap, pointer, size);
  if (result == NULL && size != 0) errno = ENOMEM;
  return result;
}
void *memalign(size_t alignment, size_t size) {
  ensure_heap();
  if (alignment == 0 || (alignment & (alignment - 1)) != 0) { errno = EINVAL; return NULL; }
  if (size > capacity || alignment > capacity) { errno = ENOMEM; return NULL; }
  void *result = cmpct_aligned_alloc_impl(heap, size, alignment);
  if (result == NULL) errno = ENOMEM;
  return result;
}
size_t malloc_usable_size(void *pointer) {
  if (pointer == NULL) return 0;
  ensure_heap();
  return cmpct_get_allocated_size_impl(heap, pointer);
}

// Newlib can call these directly without passing through Pico's malloc wrappers.
static void *reentrant_result(struct _reent *r, void *result, int failed) {
  if (failed) r->_errno = errno;
  return result;
}
void *_malloc_r(struct _reent *r, size_t size) {
  void *result = malloc(size);
  return reentrant_result(r, result, result == NULL);
}
void _free_r(struct _reent *r, void *pointer) { (void)r; free(pointer); }
void *_calloc_r(struct _reent *r, size_t count, size_t size) {
  void *result = calloc(count, size);
  return reentrant_result(r, result, result == NULL);
}
void *_realloc_r(struct _reent *r, void *pointer, size_t size) {
  void *result = realloc(pointer, size);
  return reentrant_result(r, result, result == NULL && size != 0);
}
void *_memalign_r(struct _reent *r, size_t alignment, size_t size) {
  void *result = memalign(alignment, size);
  return reentrant_result(r, result, result == NULL);
}
size_t _malloc_usable_size_r(struct _reent *r, void *pointer) {
  (void)r;
  return malloc_usable_size(pointer);
}

// No second allocator may acquire this region through sbrk.
void *_sbrk(int increment) { (void)increment; errno = ENOMEM; return (void *)-1; }

void toit_rp2040_heap_info(multi_heap_info_t *info) {
  ensure_heap();
  cmpct_get_info_impl(heap, info);
}
