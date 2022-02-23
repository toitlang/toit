// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "flags.h"
#include "heap.h"
#include "heap_report.h"
#include "memory.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "scheduler.h"
#include "utils.h"
#include "vm.h"

namespace toit {

void Usage::print(int indent) {
  int unused = reserved() == 0 ? 0 : 100 - (100 * allocated())/reserved();
  printf("%*d KB %s", indent + 4, reserved() >> KB_LOG2, name());
  if (unused != 0) printf(", %d%% waste", unused);
  printf("\n");
}

template<typename T> inline T translate_address(T value, int delta) {
  if (value == null) return null;
  return reinterpret_cast<T>(reinterpret_cast<uword>(value) + delta);
}

HeapMemory::HeapMemory() {
  _memory_mutex = OS::allocate_mutex(0, "Memory mutex");
}

HeapMemory::~HeapMemory() {
  // Unlink freelist to avoid asserts on closedown.
  while (Chunk* chunk = _free_list.remove_first()) {
    OS::free_chunk(chunk);
  }
  OS::dispose(_memory_mutex);
}

Chunk* HeapMemory::allocate_chunk_during_scavenge(RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  ASSERT(_in_scavenge);
  // If we are in a scavenge we take chunks from the free-list, which is used
  // to reserve memory for GCs.
  Chunk* chunk = _free_list.remove_first();
  if (!chunk) {
    // _free_list should always reserve enough chunks for a GC, but we
    // can be unlucky with the packing, and have to allocate more during
    // a GC.
    chunk = OS::allocate_chunk();
    if (!chunk) {
      OS::out_of_memory("Out of memory due to heap fragmentation");
    }
  }
  // We don't need to update the _largest_number_of_chunks_in_a_heap field
  // because that is done at the end of scavenge.
  return chunk;
}

Chunk* HeapMemory::allocate_chunk(RawHeap* heap) {
  Locker scoped(_memory_mutex);
  ASSERT(!_in_scavenge);

  Chunk* result = null;

  // If we will still have enough free chunks to GC the largest heap even after
  // taking one, then take a free chunk.  Subtract one in case this is the
  // largest heap in which case when this heap grows we will also need a larger
  // freelist in order to guarantee completion of a scavenge.
  if (_free_list.length() - 1 > _largest_number_of_chunks_in_a_heap) {
    result = _free_list.remove_first();
  } else {
    result = OS::allocate_chunk();
    if (!result) return null;
    while (heap->number_of_chunks() >= _free_list.length()) {
      Chunk* reserved_chunk = OS::allocate_chunk();
      if (!reserved_chunk) {
        // Not enough memory to both allocate a chunk and to reserve one for GC.
        OS::free_chunk(result);
        return null;
      }
      _free_list.prepend(reserved_chunk);
    }
  }
  // If giving this chunk to the heap makes the heap the largest, then update
  // _largest_number_of_chunks_in_a_heap.
  if (heap->number_of_chunks() + 1 >= _largest_number_of_chunks_in_a_heap) {
    _largest_number_of_chunks_in_a_heap = heap->number_of_chunks() + 1;
  }
  return result;
}

// For the initial chunk of a new process, the heap has not been created yet.
// In this case we don't need to worry about reserving space for GC since the
// new heap cannot be the largest heap in the system.
Chunk* HeapMemory::allocate_initial_chunk() {
  Locker scoped(_memory_mutex);
  ASSERT(!_in_scavenge);

  Chunk* result = null;

  // If we will still have enough free chunks to GC the largest heap even after
  // taking one, then take a free chunk.
  if (_free_list.length() > _largest_number_of_chunks_in_a_heap) {
    result = _free_list.remove_first();
  } else {
    result = OS::allocate_chunk();
    if (!result) return null;
  }
  return result;
}

void HeapMemory::free_unused_chunk(Chunk* chunk) {
  Locker scoped(_memory_mutex);
  chunk->_reset();
  _free_list.prepend(chunk);
}

void HeapMemory::free_chunk(Chunk* chunk, RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  ASSERT(_in_scavenge);
  chunk->_reset();
  _free_list.prepend(chunk);
}

void HeapMemory::enter_scavenge(RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  _in_scavenge = true;
  // We would like to assert that heap->number_of_chunks() <=
  // _free_list.length(), but this is not always the case if a GC ran into
  // fragmentation and the memory use grew during GC, but no extra pages could
  // be allocated.
}

void HeapMemory::leave_scavenge(RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  ASSERT(_in_scavenge)
  // Heap should not grow during scavenge, but we can be unlucky with the
  // fragmentation and reordering of objects in a GC.
  while (heap->number_of_chunks() > _free_list.length()) {
    Chunk* reserved_chunk = OS::allocate_chunk();
    if (!reserved_chunk) {
      // This is a bad situation caused by fragmentation, because we can't
      // allocate enough reserve space for the next GC, but there is little
      // point in proactively killing the VM here.  It may die on the next
      // allocation due to OOM though.
      break;
    }
    _free_list.prepend(reserved_chunk);
  }
  // If the heap shrank during GC we may be able to free up some reserve
  // memory now.  We don't do this as agressively on Unix because it just
  // churns the memory map.
#ifdef TOIT_FREERTOS
#define CALCULATE_SPARE_MEMORY(largest_number_of_chunks_in_a_heap) \
    (largest_number_of_chunks_in_a_heap)
#else
#define CALCULATE_SPARE_MEMORY(largest_number_of_chunks_in_a_heap) \
    ((largest_number_of_chunks_in_a_heap * 2) + 3)
#endif
  word new_largest_number_of_chunks_in_a_heap =
      VM::current()->scheduler()->largest_number_of_chunks_in_a_process();
  while (CALCULATE_SPARE_MEMORY(new_largest_number_of_chunks_in_a_heap) < _free_list.length()) {
    Chunk* chunk = _free_list.remove_first();
    ASSERT(chunk);
    OS::free_chunk(chunk);
  }
#ifdef TOIT_FREERTOS
  // To improve fragmentation, we replace every chunk on the free chunk list
  // with a newly allocated chunk.  The allocator takes the lowest address it
  // can find, so this should move the spare chunks to the end.

  // Get lowest-address chunk that is available.
  int reserved_chunks = _free_list.length();
  Chunk* defrag_chunk = OS::allocate_chunk();
  Chunk** chunk_array = reinterpret_cast<Chunk**>(malloc(sizeof(Chunk*) * reserved_chunks));
  int new_chunks_allocated = 0;
  while (chunk_array != null && defrag_chunk != null && new_chunks_allocated < reserved_chunks) {
    Chunk* old_chunk = _free_list.remove_first();
    if (old_chunk < defrag_chunk) {
      // The current chunk is lower address than the lowest-address chunk
      // that is available, so we keep it.
      chunk_array[new_chunks_allocated++] = old_chunk;
    } else {
      // The current chunk is lower address than the lowest-address chunk
      // Use the lower-address defrag_chunk instead of the one we were using.
      chunk_array[new_chunks_allocated++] = defrag_chunk;
      // Free the one we were using.
      OS::free_chunk(old_chunk);
      // Get the lowest-address chunk that is available.
      defrag_chunk = OS::allocate_chunk();
    }
  }
  // Insertion sort of the new chunks.
  if (defrag_chunk) OS::free_chunk(defrag_chunk);
  for (int j = 0; j < new_chunks_allocated; j++) {
    Chunk* highest_chunk = null;
    int highest_chunk_index = -1;
    for (int k = 0; k < new_chunks_allocated; k++) {
      if (chunk_array[k] > highest_chunk) {
        highest_chunk = chunk_array[k];
        highest_chunk_index = k;
      }
    }
    _free_list.prepend(highest_chunk);
    chunk_array[highest_chunk_index] = null;
  }
  free(chunk_array);
#endif
  _largest_number_of_chunks_in_a_heap = new_largest_number_of_chunks_in_a_heap;
  _in_scavenge = false;
}

void RawHeap::take_chunks(Chunk* chunks) {
  _chunks.take_chunks(chunks, this);
}

void RawHeap::print() {
  printf("%p RawHeap\n", this);
  _chunks.print();
  printf("  SIZE = %d\n", _chunks.payload_size());
}

Usage RawHeap::usage(const char* name = "heap") {
  int allocated = _chunks.length() * TOIT_PAGE_SIZE;
  int used = object_size();
  return Usage(name, allocated, used);
}

}
