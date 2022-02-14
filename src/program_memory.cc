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
#include "program_heap.h"
#include "heap_report.h"
#include "program_memory.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "scheduler.h"
#include "utils.h"
#include "vm.h"

namespace toit {

void ProgramUsage::print(int indent) {
  int unused = reserved() == 0 ? 0 : 100 - (100 * allocated())/reserved();
  printf("%*d KB %s", indent + 4, reserved() >> KB_LOG2, name());
  if (unused != 0) printf(", %d%% waste", unused);
  printf("\n");
}

HeapObject* ProgramBlock::allocate_raw(int byte_size) {
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

ProgramBlock* ProgramBlock::from(HeapObject* object) {
  return reinterpret_cast<ProgramBlock*>(Utils::round_down(reinterpret_cast<uword>(object), TOIT_PAGE_SIZE));
}

void ProgramBlock::wipe() {
  uint8* begin = unvoid_cast<uint8*>(base());
  uint8* end   = unvoid_cast<uint8*>(limit());
  memset(begin, 0, end - begin);
}

bool ProgramBlock::contains(HeapObject* object) {
  uword begin = reinterpret_cast<uword>(base());
  uword end   = reinterpret_cast<uword>(top());
  uword value = reinterpret_cast<uword>(object);
  return (begin < value) && (value < end);  // Remember object is tagged.
}

void ProgramBlock::print() {
  printf("%p Block [%p]\n", this, top());
}

void ProgramBlockList::print() {
  for (auto block : _blocks) {
    printf(" - ");
    block->print();
  }
}

int ProgramBlockList::payload_size() const {
  int result = 0;
  for (auto block : _blocks) {
    result += block->payload_size();
  }
  return result;
}

ProgramBlockList::~ProgramBlockList() {
  set_writable(true);
  while (_blocks.remove_first());
}

void ProgramBlockList::free_blocks(ProgramRawHeap* heap) {
  while (auto block = _blocks.remove_first()) {
    block->wipe();
    VM::current()->program_heap_memory()->free_block(block, heap);
  }
  _length = 0;
}

void ProgramBlockList::take_blocks(ProgramBlockList* list, ProgramRawHeap* heap) {
  // First free the unused blocks after the scavenge.
  free_blocks(heap);
  _blocks = list->_blocks;
  _length = list->_length;
  list->_length = 0;
  list->_blocks = ProgramBlockLinkedList();
}

void ProgramBlockList::set_writable(bool value) {
  for (auto block : _blocks) {
    VM::current()->program_heap_memory()->set_writable(block, value);
  }
}

template<typename T> inline T translate_address(T value, int delta) {
  if (value == null) return null;
  return reinterpret_cast<T>(reinterpret_cast<uword>(value) + delta);
}

void ProgramBlock::shrink_top(int delta) {
  ASSERT(delta >= 0);
  _top = translate_address(_top, -delta);
}

void ProgramBlock::do_pointers(Program* program, PointerCallback* callback) {
  for (void* p = base(); p < top(); p = Utils::address_at(p, HeapObject::cast(p)->size(program))) {
    HeapObject* obj = HeapObject::cast(p);
    obj->do_pointers(program, callback);
  }
  LinkedListPatcher<ProgramBlock> hack(*this);
  callback->c_address(reinterpret_cast<void**>(hack.next_cell()));
  bool is_sentinel = true;
  callback->c_address(reinterpret_cast<void**>(&_top), is_sentinel);
}

void ProgramBlockList::do_pointers(Program* program, PointerCallback* callback) {
  ProgramBlock* previous = null;
  for (auto block : _blocks) {
    if (previous) previous->do_pointers(program, callback);
    previous = block;
  }
  if (previous) previous->do_pointers(program, callback);
  LinkedListPatcher<ProgramBlock> hack(_blocks);
  callback->c_address(reinterpret_cast<void**>(hack.next_cell()));
  callback->c_address(reinterpret_cast<void**>(hack.tail_cell()));
}

ProgramHeapMemory::ProgramHeapMemory() {
  _memory_mutex = OS::allocate_mutex(0, "Memory mutex");
}

ProgramHeapMemory::~ProgramHeapMemory() {
  // Unlink freelist to avoid asserts on closedown.
  while (ProgramBlock* block = _free_list.remove_first()) {
#ifndef TOIT_FREERTOS
    OS::free_block(block);
#else
    USE(block);
#endif
  }
  OS::dispose(_memory_mutex);
}

ProgramBlock* ProgramHeapMemory::allocate_block(ProgramRawHeap* heap) {
  Locker scoped(_memory_mutex);

  ProgramBlock* result = null;

  // If we will still have enough free blocks to GC the largest heap even after
  // taking one, then take a free block.  Subtract one in case this is the
  // largest heap in which case when this heap grows we will also need a larger
  // freelist in order to guarantee completion of a scavenge.
  if (_free_list.length() - 1 > _largest_number_of_blocks_in_a_heap) {
    result = _free_list.remove_first();
  } else {
    result = OS::allocate_program_block();
    if (!result) return null;
    while (heap->number_of_blocks() >= _free_list.length()) {
      ProgramBlock* reserved_block = OS::allocate_program_block();
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
ProgramBlock* ProgramHeapMemory::allocate_initial_block() {
  Locker scoped(_memory_mutex);

  ProgramBlock* result = null;

  // If we will still have enough free blocks to GC the largest heap even after
  // taking one, then take a free block.
  if (_free_list.length() > _largest_number_of_blocks_in_a_heap) {
    result = _free_list.remove_first();
  } else {
    result = OS::allocate_program_block();
    if (!result) return null;
  }
  return result;
}

void ProgramHeapMemory::free_unused_block(ProgramBlock* block) {
  Locker scoped(_memory_mutex);
  block->_reset();
  _free_list.prepend(block);
}

void ProgramHeapMemory::free_block(ProgramBlock* block, ProgramRawHeap* heap) {
  ASSERT(OS::is_locked(_memory_mutex));
  // If the block's owner is null we know it is program space and the memory is
  // read only.  This does not happen on the device.
#ifdef TOIT_FREERTOS
  FATAL("Program memory freed on device");
#else
  set_writable(block, true);
#endif
  block->_reset();
  _free_list.prepend(block);
}

void ProgramHeapMemory::set_writable(ProgramBlock* block, bool value) {
#ifndef TOIT_FREERTOS
  OS::set_writable(block, value);
#endif
}

void ProgramRawHeap::take_blocks(ProgramBlockList* blocks) {
  _blocks.take_blocks(blocks, this);
}

void ProgramRawHeap::print() {
  printf("%p RawHeap\n", this);
  _blocks.print();
  printf("  SIZE = %d\n", _blocks.payload_size());
}

ProgramUsage ProgramRawHeap::usage(const char* name = "heap") {
  int allocated = _blocks.length() * TOIT_PAGE_SIZE;
  int used = object_size();
  return ProgramUsage(name, allocated, used);
}

}
