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

HeapObject* Block::allocate_raw(int byte_size) {
  ASSERT(byte_size > 0);
  ASSERT(Utils::is_aligned(byte_size, WORD_SIZE));
  void* result = top();
  void* new_top = Utils::address_at(top(), byte_size);
  if (new_top <= limit()) {
    _top = new_top;
    return HeapObject::cast(result);
  }
  return null;
}

Block* Block::from(HeapObject* object) {
  return reinterpret_cast<Block*>(Utils::round_down(reinterpret_cast<uword>(object), TOIT_PAGE_SIZE));
}

void Block::wipe() {
  uint8* begin = unvoid_cast<uint8*>(base());
  uint8* end   = unvoid_cast<uint8*>(limit());
  memset(begin, 0, end - begin);
}

bool Block::contains(HeapObject* object) {
  uword begin = reinterpret_cast<uword>(base());
  uword end   = reinterpret_cast<uword>(top());
  uword value = reinterpret_cast<uword>(object);
  return (begin < value) && (value < end);  // Remember object is tagged.
}

void Block::print() {
  printf("%p Block [%p]\n", this, top());
}

void BlockList::print() {
  for (auto block : _blocks) {
    printf(" - ");
    block->print();
  }
}

int BlockList::payload_size() const {
  int result = 0;
  for (auto block : _blocks) {
    result += block->payload_size();
  }
  return result;
}

BlockList::~BlockList() {
  while (_blocks.remove_first());
}

void BlockList::free_blocks(RawHeap* heap) {
  while (auto block = _blocks.remove_first()) {
    block->wipe();
    VM::current()->heap_memory()->free_block(block, heap);
  }
  _length = 0;
}

void BlockList::take_blocks(BlockList* list, RawHeap* heap) {
  // First free the unused blocks after the scavenge.
  free_blocks(heap);
  _blocks = list->_blocks;
  _length = list->_length;
  list->_length = 0;
  list->_blocks = BlockLinkedList();
}

template<typename T> inline T translate_address(T value, int delta) {
  if (value == null) return null;
  return reinterpret_cast<T>(reinterpret_cast<uword>(value) + delta);
}

void Block::shrink_top(int delta) {
  ASSERT(delta >= 0);
  _top = translate_address(_top, -delta);
}

HeapMemory::HeapMemory() {
  _memory_mutex = OS::allocate_mutex(0, "Memory mutex");
}

HeapMemory::~HeapMemory() {
  // Unlink freelist to avoid asserts on closedown.
  while (Block* block = _free_list.remove_first()) {
    OS::free_block(block);
  }
  OS::dispose(_memory_mutex);
}

Block* HeapMemory::allocate_block_during_scavenge(RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  ASSERT(_in_scavenge);
  // If we are in a scavenge we take blocks from the free-list, which is used
  // to reserve memory for GCs.
  Block* block = _free_list.remove_first();
  if (!block) {
    // _free_list should always reserve enough blocks for a GC, but we
    // can be unlucky with the packing, and have to allocate more during
    // a GC.
    block = OS::allocate_block();
    if (!block) {
      OS::out_of_memory("Out of memory due to heap fragmentation");
    }
  }
  block->_set_process(heap->owner());
  // We don't need to update the _largest_number_of_blocks_in_a_heap field
  // because that is done at the end of scavenge.
  return block;
}

Block* HeapMemory::allocate_block(RawHeap* heap) {
  Locker scoped(_memory_mutex);
  ASSERT(!_in_scavenge);

  Block* result = null;

  // If we will still have enough free blocks to GC the largest heap even after
  // taking one, then take a free block.  Subtract one in case this is the
  // largest heap in which case when this heap grows we will also need a larger
  // freelist in order to guarantee completion of a scavenge.
  if (_free_list.length() - 1 > _largest_number_of_blocks_in_a_heap) {
    result = _free_list.remove_first();
  } else {
    result = OS::allocate_block();
    if (!result) return null;
    while (heap->number_of_blocks() >= _free_list.length()) {
      Block* reserved_block = OS::allocate_block();
      if (!reserved_block) {
        // Not enough memory to both allocate a block and to reserve one for GC.
        OS::free_block(result);
        return null;
      }
      _free_list.prepend(reserved_block);
    }
  }
  result->_set_process(heap->owner());
  // If giving this block to the heap makes the heap the largest, then update
  // _largest_number_of_blocks_in_a_heap.
  if (heap->number_of_blocks() + 1 >= _largest_number_of_blocks_in_a_heap) {
    _largest_number_of_blocks_in_a_heap = heap->number_of_blocks() + 1;
  }
  return result;
}

// For the initial block of a new process, the heap has not been created yet.
// In this case we don't need to worry about reserving space for GC since the
// new heap cannot be the largest heap in the system.
Block* HeapMemory::allocate_initial_block() {
  Locker scoped(_memory_mutex);
  ASSERT(!_in_scavenge);

  Block* result = null;

  // If we will still have enough free blocks to GC the largest heap even after
  // taking one, then take a free block.
  if (_free_list.length() > _largest_number_of_blocks_in_a_heap) {
    result = _free_list.remove_first();
  } else {
    result = OS::allocate_block();
    if (!result) return null;
  }
  result->_set_process(null);
  return result;
}

void HeapMemory::free_unused_block(Block* block) {
  Locker scoped(_memory_mutex);
  block->_reset();
  _free_list.prepend(block);
}

void HeapMemory::free_block(Block* block, RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  ASSERT(_in_scavenge);
  // If the block's owner is null we know it is program space and the memory is
  // read only.  This does not happen on the device.
  ASSERT(!block->is_program());
  ASSERT(_in_scavenge);
  block->_reset();
  _free_list.prepend(block);
}

void HeapMemory::enter_scavenge(RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  _in_scavenge = true;
  // We would like to assert that heap->number_of_blocks() <=
  // _free_list.length(), but this is not always the case if a GC ran into
  // fragmentation and the memory use grew during GC, but no extra pages could
  // be allocated.
}

void HeapMemory::leave_scavenge(RawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  ASSERT(_in_scavenge)
  // Heap should not grow during scavenge, but we can be unlucky with the
  // fragmentation and reordering of objects in a GC.
  while (heap->number_of_blocks() > _free_list.length()) {
    Block* reserved_block = OS::allocate_block();
    if (!reserved_block) {
      // This is a bad situation caused by fragmentation, because we can't
      // allocate enough reserve space for the next GC, but there is little
      // point in proactively killing the VM here.  It may die on the next
      // allocation due to OOM though.
      break;
    }
    _free_list.prepend(reserved_block);
  }
  // If the heap shrank during GC we may be able to free up some reserve
  // memory now.  We don't do this as agressively on Unix because it just
  // churns the memory map.
#ifdef TOIT_FREERTOS
#define CALCULATE_SPARE_MEMORY(largest_number_of_blocks_in_a_heap) \
    (largest_number_of_blocks_in_a_heap)
#else
#define CALCULATE_SPARE_MEMORY(largest_number_of_blocks_in_a_heap) \
    ((largest_number_of_blocks_in_a_heap * 2) + 3)
#endif
  word new_largest_number_of_blocks_in_a_heap =
      VM::current()->scheduler()->largest_number_of_blocks_in_a_process();
  while (CALCULATE_SPARE_MEMORY(new_largest_number_of_blocks_in_a_heap) < _free_list.length()) {
    Block* block = _free_list.remove_first();
    ASSERT(block);
    OS::free_block(block);
  }
#ifdef TOIT_FREERTOS
  // To improve fragmentation, we replace every block on the free block list
  // with a newly allocated block.  The allocator takes the lowest address it
  // can find, so this should move the spare blocks to the end.

  // Get lowest-address block that is available.
  int reserved_blocks = _free_list.length();
  Block* defrag_block = OS::allocate_block();
  Block** block_array = reinterpret_cast<Block**>(malloc(sizeof(Block*) * reserved_blocks));
  int new_blocks_allocated = 0;
  while (block_array != null && defrag_block != null && new_blocks_allocated < reserved_blocks) {
    Block* old_block = _free_list.remove_first();
    if (old_block < defrag_block) {
      // The current block is lower address than the lowest-address block
      // that is available, so we keep it.
      block_array[new_blocks_allocated++] = old_block;
    } else {
      // The current block is lower address than the lowest-address block
      // Use the lower-address defrag_block instead of the one we were using.
      block_array[new_blocks_allocated++] = defrag_block;
      // Free the one we were using.
      OS::free_block(old_block);
      // Get the lowest-address block that is available.
      defrag_block = OS::allocate_block();
    }
  }
  // Insertion sort of the new blocks.
  if (defrag_block) OS::free_block(defrag_block);
  for (int j = 0; j < new_blocks_allocated; j++) {
    Block* highest_block = null;
    int highest_block_index = -1;
    for (int k = 0; k < new_blocks_allocated; k++) {
      if (block_array[k] > highest_block) {
        highest_block = block_array[k];
        highest_block_index = k;
      }
    }
    _free_list.prepend(highest_block);
    block_array[highest_block_index] = null;
  }
  free(block_array);
#endif
  _largest_number_of_blocks_in_a_heap = new_largest_number_of_blocks_in_a_heap;
  _in_scavenge = false;
}

void RawHeap::take_blocks(BlockList* blocks) {
  _blocks.take_blocks(blocks, this);
}

void RawHeap::print() {
  printf("%p RawHeap\n", this);
  _blocks.print();
  printf("  SIZE = %d\n", _blocks.payload_size());
}

Usage RawHeap::usage(const char* name = "heap") {
  int allocated = _blocks.length() * TOIT_PAGE_SIZE;
  int used = object_size();
  return Usage(name, allocated, used);
}

}
