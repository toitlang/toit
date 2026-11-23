// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/heap.h"
#include "../../src/objects_inline.h"

int main() {
  using namespace toit;
  ObjectHeap heap(null, null, null, null, null);
  if (heap.update_pending_limit() != TOIT_PAGE_SIZE) FATAL("empty heap limit");

  // Exercise the real atomic accounting without allocating large buffers.
  heap.register_external_allocation(INTPTR_MAX);
  if (heap.update_pending_limit() != INTPTR_MAX) FATAL("doubled limit overflow");
  heap.leave_primitive();
  if (heap.max_external_allocation() != 0) FATAL("exactly at limit");

  heap.register_external_allocation(1);
  if (heap.update_pending_limit() != INTPTR_MAX) FATAL("unsigned external byte count");
  if (heap.max_external_allocation() >= 0) FATAL("over limit");
  heap.set_max_heap_size(TOIT_PAGE_SIZE);
  if (heap.update_pending_limit() != TOIT_PAGE_SIZE) FATAL("configured cap");
  heap.leave_primitive();
  if (heap.max_external_allocation() >= 0) FATAL("over configured cap");

  heap.unregister_external_allocation(1);
  heap.unregister_external_allocation(INTPTR_MAX);
  if (heap.max_external_allocation() != TOIT_PAGE_SIZE) FATAL("released bytes");
}
