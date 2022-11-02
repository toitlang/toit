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

#include "heap_roots.h"
#include "linked.h"
#include "objects.h"
#include "primitive.h"
#include "printing.h"
#include "third_party/dartino/two_space_heap.h"

namespace toit {

class ObjectNotifier;

// A class that uses a RAII destructor to free memory already
// allocated if a later allocation fails.
class InitialMemoryManager {
 public:
  Chunk* initial_chunk = null;

  void dont_auto_free() {
    initial_chunk = null;
  }

  // Allocates initial pages for heap.  Returns success.
  bool allocate();

  // Frees any of the fields that are not null.
  ~InitialMemoryManager();
};

class ObjectHeap {
 public:
  ObjectHeap(Program* program, Process* owner, Chunk* initial_chunk);
  ~ObjectHeap();

  // TODO: In the new heap there need not be a max allocation size.
  static int max_allocation_size() { return TOIT_PAGE_SIZE - 96; }

  inline void do_objects(const std::function<void (HeapObject*)>& func) {
    two_space_heap_.do_objects(func);
  }

  inline bool cross_process_gc_needed() const { return two_space_heap_.cross_process_gc_needed(); }

  // Shared allocation operations.
  Instance* allocate_instance(Smi* class_id);
  Instance* allocate_instance(TypeTag class_tag, Smi* class_id, Smi* instance_size);
  Array* allocate_array(int length, Object* filler);
  ByteArray* allocate_external_byte_array(int length, uint8* memory, bool dispose, bool clear_content = true);
  String* allocate_external_string(int length, uint8* memory, bool dispose);
  ByteArray* allocate_internal_byte_array(int length);
  String* allocate_internal_string(int length);
  Double* allocate_double(double value);
  LargeInteger* allocate_large_integer(int64 value);

  void process_registered_finalizers(RootCallback* ss, LivenessOracle* from_space);
  void process_registered_vm_finalizers(RootCallback* ss, LivenessOracle* from_space);

  Program* program() const { return program_; }

  int64 total_bytes_allocated() const { return total_external_memory_ + two_space_heap_.total_bytes_allocated(); }
  int64 bytes_reserved() const { return external_memory_ + two_space_heap_.size(); }
  int64 bytes_allocated() const { return external_memory_ + two_space_heap_.used(); }
  uword external_memory() const { return external_memory_; }
  bool has_limit() const { return limit_ != max_heap_size_; }
  uword limit() const { return limit_; }

  void enter_gc() {}
  void leave_gc() {}
  void enter_no_gc() {}
  void leave_no_gc() {}

  bool system_refused_memory() const {
    return
        last_allocation_result_ == ALLOCATION_OUT_OF_MEMORY ||
        two_space_heap_.cross_process_gc_needed();
  }

  enum AllocationResult {
    ALLOCATION_SUCCESS,
    ALLOCATION_HIT_LIMIT,     // The process hit its self-imposed limit, we should run GC.
    ALLOCATION_OUT_OF_MEMORY  // The system is out of memory, we should GC other processes.
  };

  void set_last_allocation_result(AllocationResult result) {
    last_allocation_result_ = result;
  }

  Process* owner() { return owner_; }

 public:
  ObjectHeap(Program* program, Process* owner);

  Task* allocate_task();
  Stack* allocate_stack(int length);
  // Convenience methods for allocating proxy like objects.
  ByteArray* allocate_proxy(int length, uint8* memory, bool dispose = false) {
    return allocate_external_byte_array(length, memory, dispose, false);
  }
  ByteArray* allocate_proxy(bool dispose = false) {
    return allocate_proxy(0, null, dispose);
  }

  void print(Printer* printer);

  Object** global_variables() const { return global_variables_; }
  Task* task() { return task_; }
  void set_task(Task* task);

  // Garbage collection operation for runtime objects.
  GcType gc(bool try_hard);

  bool add_finalizer(HeapObject* key, Object* lambda);
  bool has_finalizer(HeapObject* key, Object* lambda);
  bool remove_finalizer(HeapObject* key);

  bool add_vm_finalizer(HeapObject* key);
  bool remove_vm_finalizer(HeapObject* key);

  bool has_finalizer_to_run() const { return !runnable_finalizers_.is_empty(); }
  Object* next_finalizer_to_run();

  // Tells how many gc operations this heap has experienced.
  int gc_count(GcType type) {
    if (type == NEW_SPACE_GC) return gc_count_;
    if (type == FULL_GC) return full_gc_count_;
    if (type == COMPACTING_GC) return full_compacting_gc_count_;
    UNREACHABLE();
  }

  void add_external_root(HeapRoot* element) { external_roots_.prepend(element); }
  void remove_external_root(HeapRoot* element) { element->unlink(); }

  void set_max_heap_size(word bytes) { max_heap_size_ = bytes; }
  word max_heap_size() const { return max_heap_size_; }

  word max_external_allocation();
  void register_external_allocation(word size);
  void unregister_external_allocation(word size);
  bool has_max_heap_size() const { return max_heap_size_ != 0; }

  void check_install_heap_limit() {
    if (limit_ != pending_limit_) install_heap_limit();
  }

  void iterate_roots(RootCallback* callback);

  // Update the memory limit for triggering the next old-space GC.  We base
  // this on a multiple of the number of chunks in use and the externally
  // allocated memory just after the previous GC.
  word update_pending_limit();

 private:
  Program* const program_;
  HeapObject* _allocate_raw(int byte_size) {
    return two_space_heap_.allocate(byte_size);
  }

  void install_heap_limit();

  bool in_gc_ = false;
  bool gc_allowed_ = true;
  AllocationResult last_allocation_result_ = ALLOCATION_SUCCESS;

  Process* owner_;
  TwoSpaceHeap two_space_heap_;

  static const word _UNLIMITED_EXPANSION = 0x7fffffff;

  // Number of bytes used before forcing a GC, including external memory.
  // Set to zero to have no limit.
  word limit_ = 0;
  // This limit will be installed at the end of the current primitive.
  word pending_limit_ = 0;

  word max_heap_size_ = 0;  // Configured max heap size, incl. external allocation.
  std::atomic<word> external_memory_;  // Allocated external memory in bytes.
  std::atomic<word> total_external_memory_;  // Includes memory that was later freed.

  Task* task_ = null;
  ObjectNotifierList object_notifiers_;

  // A finalizer is in one of the following lists.
  FinalizerNodeFIFO registered_finalizers_;       // Contains registered finalizers.
  FinalizerNodeFIFO runnable_finalizers_;         // Contains finalizers that must be executed.
  VMFinalizerNodeFIFO registered_vm_finalizers_;  // Contains registered VM finalizers.
  ObjectNotifier* finalizer_notifier_ = null;

  int gc_count_ = 0;
  int full_gc_count_ = 0;
  int full_compacting_gc_count_ = 0;
  Object** global_variables_ = null;

  HeapRootList external_roots_;

  friend class ObjectNotifier;
  friend class Process;
};

class NoGC {
 public:
  explicit NoGC(ObjectHeap* heap) : heap_(heap) {
    heap->enter_no_gc();
  }
  ~NoGC() {
    heap_->leave_no_gc();
  }

 private:
  ObjectHeap* heap_;
};

} // namespace toit
