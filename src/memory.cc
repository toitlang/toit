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
  block->_reset();
  _free_list.prepend(block);
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
