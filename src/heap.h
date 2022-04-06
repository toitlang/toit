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
#include "memory.h"
#include "objects.h"
#include "primitive.h"
#include "printing.h"
#include "third_party/dartino/two_space_heap.h"

extern "C" uword toit_image;
extern "C" uword toit_image_size;

namespace toit {

class ObjectNotifier;

#ifdef LEGACY_GC
typedef Block InitialMemory;
#else
struct InitialMemory {
  Chunk* chunk_1;
  Chunk* chunk_2;
};
#endif

// A class that uses a RAII destructor to free memory already
// allocated if a later alllocation fails.
class InitialMemoryManager {
 public:
#ifdef LEGACY_GC
  Block* initial_memory = null;
#else
  InitialMemory* initial_memory = &chunks;
  InitialMemory chunks = {null, null};
#endif

  void dont_auto_free() {
#ifdef LEGACY_GC
    initial_memory = null;
#else
    chunks.chunk_1 = null;
    chunks.chunk_2 = null;
#endif
  }

  // Allocates initial pages for heap.  Returns success.
  bool allocate();

  // Frees any of the fields that are not null.
  ~InitialMemoryManager();
};

#ifdef LEGACY_GC

// Legacy-GC: An object heap contains all objects created at runtime.
class ObjectHeap : public RawHeap {
 public:
  ObjectHeap(Process* owner, Program* program, Block* initial_block);
  ~ObjectHeap();

  class Iterator {
   public:
    explicit Iterator(BlockList& list, Program* program);
    HeapObject* current();
    bool eos();
    void advance();

   private:
    void ensure_started();
    BlockList& _list;
    BlockLinkedList::Iterator _iterator;
    Block* _block;
    void* _current;
    Program* _program;
  };

  Iterator object_iterator() { return Iterator(_blocks, _program); }

  static int max_allocation_size() { return Block::max_payload_size(); }

  void do_objects(const std::function<void (HeapObject*)>& func) {
    Iterator iterator(_blocks, _program);
    while (!iterator.eos()) {
      HeapObject* object = iterator.current();
      func(object);
      iterator.advance();
    }
  }

#else
class ObjectHeap {
 public:
  ObjectHeap(Program* program, Process* owner, InitialMemory* initial_memory);
  ~ObjectHeap();

  // TODO: In the new heap there is no max allocation size.
  static int max_allocation_size() { return TOIT_PAGE_SIZE - 96; }

  inline void do_objects(const std::function<void (HeapObject*)>& func) {
    _two_space_heap.do_objects(func);
  }

#endif

  // Shared allocation operations.
  Instance* allocate_instance(Smi* class_id);
  Instance* allocate_instance(TypeTag class_tag, Smi* class_id, Smi* instance_size);
  Array* allocate_array(int length, Object* filler);
  Array* allocate_array(int length);
  ByteArray* allocate_external_byte_array(int length, uint8* memory, bool dispose, bool clear_content = true);
  String* allocate_external_string(int length, uint8* memory, bool dispose);
  ByteArray* allocate_internal_byte_array(int length);
  String* allocate_internal_string(int length);
  Double* allocate_double(double value);
  LargeInteger* allocate_large_integer(int64 value);

  void process_registered_finalizers(RootCallback* ss, LivenessOracle* from_space);
  void process_registered_vm_finalizers(RootCallback* ss, LivenessOracle* from_space);

  Program* program() { return _program; }

  int64 total_bytes_allocated() { return _total_bytes_allocated; }
  uword limit() { return _limit; }

#if !defined(DEPLOY) && defined(LEGACY_GC)
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
#ifndef LEGACY_GC
  Usage usage(const char* name);
  Process* owner() { return _owner; }
#endif

 public:
#ifdef LEGACY_GC
  ObjectHeap(Program* program, Process* owner, Block* initial_block);
#else
  ObjectHeap(Program* program, Process* owner);
#endif

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

  Object** global_variables() const { return _global_variables; }
  Task* task() { return _task; }
  void set_task(Task* task);

  // Garbage collection operation for runtime objects.
  int gc();

  bool add_finalizer(HeapObject* key, Object* lambda);
  bool has_finalizer(HeapObject* key, Object* lambda);
  bool remove_finalizer(HeapObject* key);

  bool add_vm_finalizer(HeapObject* key);
  bool remove_vm_finalizer(HeapObject* key);

  bool has_finalizer_to_run() const { return !_runnable_finalizers.is_empty(); }
  Object* next_finalizer_to_run();

  // Tells how many gc operations this heap has experienced.
  int gc_count() { return _gc_count; }

  void add_external_root(HeapRoot* element) { _external_roots.prepend(element); }
  void remove_external_root(HeapRoot* element) { element->unlink(); }

  void set_max_heap_size(word bytes) { _max_heap_size = bytes; }
  word max_heap_size() const { return _max_heap_size; }

  bool should_allow_external_allocation(word size);
  void register_external_allocation(word size);
  void unregister_external_allocation(word size);
  bool has_max_heap_size() const { return _max_heap_size != 0; }
  void install_heap_limit() { _limit = _pending_limit; }
  void iterate_roots(RootCallback* callback);

 private:
  Program* const _program;
#ifdef LEGACY_GC
  HeapObject* _allocate_raw(int byte_size);
#else
  HeapObject* _allocate_raw(int byte_size) {
    return _two_space_heap.allocate(byte_size);
  }
#endif

  bool _in_gc = false;
  bool _gc_allowed = true;
  int64 _total_bytes_allocated = 0;
  AllocationResult _last_allocation_result = ALLOCATION_SUCCESS;

#ifndef LEGACY_GC
  Process* _owner;
  TwoSpaceHeap _two_space_heap;
#endif

  // An estimate of how much memory overhead malloc has.
  static const word _EXTERNAL_MEMORY_ALLOCATOR_OVERHEAD = 2 * sizeof(word);

  // Minimum number of heap blocks we limit ourselves to.
  static const word _MIN_BLOCK_LIMIT = 4;

  // Number of bytes used before forcing a scavenge, including external memory.
  // Set to zero to have no limit.
  word _limit = 0;
  // This limit will be installed at the end of the current primitive.
  word _pending_limit = 0;

  word _max_heap_size = 0;  // Configured max heap size, incl. external allocation.
  std::atomic<word> _external_memory;  // Allocated external memory in bytes.

  Task* _task = null;
  ObjectNotifierList _object_notifiers;

  // A finalizer is in one of the following lists.
  FinalizerNodeFIFO _registered_finalizers;       // Contains registered finalizers.
  FinalizerNodeFIFO _runnable_finalizers;         // Contains finalizers that must be executed.
  VMFinalizerNodeFIFO _registered_vm_finalizers;  // Contains registered VM finalizers.
  ObjectNotifier* _finalizer_notifier = null;

  int _gc_count = 0;
  Object** _global_variables = null;

  HeapRootList _external_roots;

  // Calculate the memory limit for scavenge based on the number of live blocks
  // and the externally allocated memory.
  word _calculate_limit();
#ifdef LEGACY_GC
  AllocationResult _expand();
#endif

  friend class ObjectNotifier;
};

class NoGC {
 public:
  explicit NoGC(ObjectHeap* heap) : _heap(heap) {
    heap->enter_no_gc();
  }
  ~NoGC() {
    _heap->leave_no_gc();
  }

 private:
  ObjectHeap* _heap;
};

} // namespace toit
