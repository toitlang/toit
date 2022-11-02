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
    top_ = new_top;
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
  for (auto block : blocks_) {
    printf(" - ");
    block->print();
  }
}

int ProgramBlockList::payload_size() const {
  int result = 0;
  for (auto block : blocks_) {
    result += block->payload_size();
  }
  return result;
}

ProgramBlockList::~ProgramBlockList() {
  set_writable(true);
  while (blocks_.remove_first());
}

void ProgramBlockList::free_blocks(ProgramRawHeap* heap) {
  while (auto block = blocks_.remove_first()) {
    block->wipe();
    // TODO: We should delete program blocks, but they are created in such a
    // strange way, that it's simpler to leak them.
  }
  length_ = 0;
}

void ProgramBlockList::take_blocks(ProgramBlockList* list, ProgramRawHeap* heap) {
  free_blocks(heap);
  blocks_ = list->blocks_;
  length_ = list->length_;
  list->length_ = 0;
  list->blocks_ = ProgramBlockLinkedList();
}

void ProgramBlockList::set_writable(bool value) {
  for (auto block : blocks_) {
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
  callback->c_address(reinterpret_cast<void**>(&top_), is_sentinel);
}

void ProgramBlockList::do_pointers(Program* program, PointerCallback* callback) {
  ProgramBlock* previous = null;
  for (auto block : blocks_) {
    if (previous) previous->do_pointers(program, callback);
    previous = block;
  }
  if (previous) previous->do_pointers(program, callback);
  LinkedListPatcher<ProgramBlock> hack(blocks_);
  callback->c_address(reinterpret_cast<void**>(hack.next_cell()));
  callback->c_address(reinterpret_cast<void**>(hack.tail_cell()));
}

ProgramHeapMemory::ProgramHeapMemory() {
  memory_mutex_ = OS::allocate_mutex(0, "Memory mutex");
}

ProgramHeapMemory::~ProgramHeapMemory() {
  OS::dispose(memory_mutex_);
}

void ProgramHeapMemory::set_writable(ProgramBlock* block, bool value) {
  OS::set_writable(block, value);
}

ProgramHeapMemory ProgramHeapMemory::instance_;

void ProgramRawHeap::take_blocks(ProgramBlockList* blocks) {
  blocks_.take_blocks(blocks, this);
}

void ProgramRawHeap::print() {
  printf("%p RawHeap\n", this);
  blocks_.print();
  printf("  SIZE = %d\n", blocks_.payload_size());
}

ProgramUsage ProgramRawHeap::usage(const char* name = "heap") {
  int allocated = blocks_.length() * TOIT_PAGE_SIZE;
  int used = object_size();
  return ProgramUsage(name, allocated, used);
}

}
