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

void ProgramBlock::wipe() {
  uint8* begin = unvoid_cast<uint8*>(base());
  uint8* end   = unvoid_cast<uint8*>(limit());
  memset(begin, 0, end - begin);
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
    // TODO: We should delete program blocks, but they are created in such a
    // strange way, that it's simpler to leak them.
  }
  _length = 0;
}

void ProgramBlockList::take_blocks(ProgramBlockList* list, ProgramRawHeap* heap) {
  free_blocks(heap);
  _blocks = list->_blocks;
  _length = list->_length;
  list->_length = 0;
  list->_blocks = ProgramBlockLinkedList();
}

void ProgramBlockList::set_writable(bool value) {
  for (auto block : _blocks) {
    ProgramHeapMemory::instance()->set_writable(block, value);
  }
}

template<typename T> inline T translate_address(T value, int delta) {
  if (value == null) return null;
  return reinterpret_cast<T>(reinterpret_cast<uword>(value) + delta);
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
  OS::dispose(_memory_mutex);
}

void ProgramHeapMemory::set_writable(ProgramBlock* block, bool value) {
  OS::set_writable(block, value);
}

ProgramHeapMemory ProgramHeapMemory::_instance;

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
