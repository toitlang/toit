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

#pragma once

#include <atomic>

#include "linked.h"
#include "program_memory.h"
#include "objects.h"
#include "primitive.h"
#include "printing.h"

extern "C" uword toit_image;
extern "C" uword toit_image_size;

namespace toit {

class ProgramHeap : public ProgramRawHeap {
 public:
  ProgramHeap(Program* program);
  ~ProgramHeap();

  class Iterator {
   public:
    explicit Iterator(ProgramBlockList& list, Program* program);
    HeapObject* current();
    bool eos();
    void advance();

   private:
    void ensure_started();
    ProgramBlockList& _list;
    ProgramBlockLinkedList::Iterator _iterator;
    ProgramBlock* _block;
    void* _current;
    Program* _program;
  };

  Iterator object_iterator() { return Iterator(_blocks, _program); }

  static int max_allocation_size(int word_size = WORD_SIZE) { return ProgramBlock::max_payload_size(word_size); }

  // Shared allocation operations.
  Instance* allocate_instance(Smi* class_id);
  Instance* allocate_instance(TypeTag class_tag, Smi* class_id, Smi* instance_size);
  Array* allocate_array(int length, Object* filler);
  Array* allocate_array(int length);
  ByteArray* allocate_external_byte_array(int length, uint8* memory);
  String* allocate_external_string(int length, uint8* memory);
  ByteArray* allocate_internal_byte_array(int length);
  String* allocate_internal_string(int length);
  Double* allocate_double(double value);
  LargeInteger* allocate_large_integer(int64 value);

  // Returns the number of bytes allocated in this heap.
  virtual int payload_size();

  // Make all blocks in this heap writable or read only.
  void set_writable(bool value) {
    _blocks.set_writable(value);
  }

  Program* program() { return _program; }

  int64 total_bytes_allocated() const { return _total_bytes_allocated; }

#ifndef DEPLOY
  void enter_gc() {
    ASSERT(!_in_gc);
    ASSERT(_gc_allowed);
    _in_gc = true;
  }
  void leave_gc() {
    ASSERT(_in_gc);
    _in_gc = false;
  }
  void enter_no_gc() {
    ASSERT(!_in_gc);
    ASSERT(_gc_allowed);
    _gc_allowed = false;
  }
  void leave_no_gc() {
    ASSERT(!_gc_allowed);
    _gc_allowed = true;
  }
#else
  void enter_gc() {}
  void leave_gc() {}
  void enter_no_gc() {}
  void leave_no_gc() {}
#endif

  bool system_refused_memory() const {
    return _last_allocation_result == ALLOCATION_OUT_OF_MEMORY;
  }

  enum AllocationResult {
    ALLOCATION_SUCCESS,
    ALLOCATION_HIT_LIMIT,     // The process hit its self-imposed limit, we should run GC.
    ALLOCATION_OUT_OF_MEMORY  // The system is out of memory, we should GC other processes.
  };

  void set_last_allocation_result(AllocationResult result) {
    _last_allocation_result = result;
  }

  void migrate_to(Program* program);

  String* allocate_string(const char* str);
  String* allocate_string(const char* str, int length);
  ByteArray* allocate_byte_array(const uint8*, int length);

 protected:
  Program* const _program;
  HeapObject* _allocate_raw(int byte_size);
  virtual AllocationResult _expand();
  bool _in_gc;
  bool _gc_allowed;
  int64 _total_bytes_allocated;
  AllocationResult _last_allocation_result;

  friend class ProgramSnapshotReader;
  friend class ObjectAllocator;
  friend class compiler::ProgramBuilder;
};

class ProgramHeapRoot;
typedef DoubleLinkedList<ProgramHeapRoot> ProgramHeapRootList;
class ProgramHeapRoot : public ProgramHeapRootList::Element {
 public:
  explicit ProgramHeapRoot(Object* obj) : _obj(obj) {}

  Object* operator*() const { return _obj; }
  Object* operator->() const { return _obj; }
  void operator=(Object* obj) { _obj = obj; }

  Object** slot() { return &_obj; }
  void unlink() { ProgramHeapRootList::Element::unlink(); }

 private:
  Object* _obj;
};

} // namespace toit
