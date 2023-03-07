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
    ProgramBlockList& list_;
    ProgramBlockLinkedList::Iterator iterator_;
    ProgramBlock* block_;
    void* current_;
    Program* program_;
  };

  Iterator object_iterator() { return Iterator(blocks_, program_); }

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
    blocks_.set_writable(value);
  }

  Program* program() { return program_; }

  int64 total_bytes_allocated() const { return total_bytes_allocated_; }

  bool system_refused_memory() const {
    return last_allocation_result_ == ALLOCATION_OUT_OF_MEMORY;
  }

  enum AllocationResult {
    ALLOCATION_SUCCESS,
    ALLOCATION_HIT_LIMIT,     // The process hit its self-imposed limit, we should run GC.
    ALLOCATION_OUT_OF_MEMORY  // The system is out of memory, we should GC other processes.
  };

  void set_last_allocation_result(AllocationResult result) {
    last_allocation_result_ = result;
  }

  void migrate_to(Program* program);

  String* allocate_string(const char* str);
  String* allocate_string(const char* str, int length);
  ByteArray* allocate_byte_array(const uint8*, int length);

 protected:
  Program* const program_;
  HeapObject* _allocate_raw(int byte_size);
  virtual AllocationResult _expand();
  bool in_gc_;
  bool gc_allowed_;
  int64 total_bytes_allocated_;
  AllocationResult last_allocation_result_;

  friend class ProgramSnapshotReader;
  friend class ObjectAllocator;
  friend class compiler::ProgramBuilder;
};

class ProgramHeapRoot;
typedef DoubleLinkedList<ProgramHeapRoot> ProgramHeapRootList;
class ProgramHeapRoot : public ProgramHeapRootList::Element {
 public:
  explicit ProgramHeapRoot(Object* obj) : obj_(obj) {}

  Object* operator*() const { return obj_; }
  Object* operator->() const { return obj_; }
  void operator=(Object* obj) { obj_ = obj; }

  Object** slot() { return &obj_; }
  void unlink() { ProgramHeapRootList::Element::unlink(); }

 private:
  Object* obj_;
};

} // namespace toit
