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
#include "memory.h"
#include "objects.h"
#include "primitive.h"
#include "printing.h"

#include "objects_inline.h"

extern "C" uword toit_image;
extern "C" uword toit_image_size;

namespace toit {

class Heap : public RawHeap {
 public:
  Heap(Process* owner, Program* program, Block* initial_block);
  ~Heap();

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

  // Returns the number of bytes allocated in this heap.
  virtual int payload_size();

  // Make all blocks in this heap writable or read only.
  void set_writable(bool value) {
    _blocks.set_writable(value);
  }

  Program* program() { return _program; }

  static inline bool in_read_only_program_heap(HeapObject* object, Heap* object_heap) {
#ifdef TOIT_FREERTOS
    // The system image is not page aligned so we can't use HeapObject::owner
    // to detect it.  But it is all in one range, so we use that instead.
    uword address = reinterpret_cast<uword>(object);
    if ((address - reinterpret_cast<uword>(&toit_image)) < toit_image_size) {
      return true;
    }
#endif
    return object->owner() != object_heap->owner();
  }

  int64 total_bytes_allocated() { return _total_bytes_allocated; }

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

class NoGC {
 public:
  explicit NoGC(Heap* heap) : _heap(heap) {
    heap->enter_no_gc();
  }
  ~NoGC() {
    _heap->leave_no_gc();
  }

 private:
  Heap* _heap;
};

// A program heap contains all the reflective structures to run the program.
// The program heap also maintains a list of active processes using this heap.
class ProgramHeap final : public Heap {
 public:
  ProgramHeap(Program* program, Block* initial_block) : Heap(null, program, initial_block) {}
  void migrate_to(Program* program);

  String* allocate_string(const char* str);
  String* allocate_string(const char* str, int length);
  ByteArray* allocate_byte_array(const uint8*, int length);
};

class ObjectNotifier;
class FinalizerNode;
class VMFinalizerNode;

typedef LinkedFIFO<FinalizerNode> FinalizerNodeFIFO;

class FinalizerNode : public FinalizerNodeFIFO::Element {
 public:
  FinalizerNode(HeapObject* key, Object* lambda)
  : _key(key), _lambda(lambda) {}
  virtual ~FinalizerNode() {}

  HeapObject* key() { return _key; }
  void set_key(HeapObject* value) { _key = value; }
  Object* lambda() { return _lambda; }

  // Garbage collection support.
  void roots_do(RootCallback* cb);

 private:
  HeapObject* _key;
  Object* _lambda;
};

typedef LinkedFIFO<VMFinalizerNode> VMFinalizerNodeFIFO;

class VMFinalizerNode : public VMFinalizerNodeFIFO::Element {
 public:
  VMFinalizerNode(HeapObject* key)
  : _key(key) {}
  virtual ~VMFinalizerNode() {}

  HeapObject* key() { return _key; }
  void set_key(HeapObject* value) { _key = value; }

  // Garbage collection support.
  void roots_do(RootCallback* cb);

  void free_external_memory(Process* process);

 private:
  HeapObject* _key;
};

typedef DoubleLinkedList<ObjectNotifier> ObjectNotifierList;

class ObjectNotifier : public ObjectNotifierList::Element {
 public:
  ObjectNotifier(Process* process, Object* object);
  ~ObjectNotifier();

  Object* object() const { return _object; }

  // Notify the state of the object has changed.
  void notify();

  void set_message(ObjectNotifyMessage* message) {
    _message = message;
  }

  void update_object(Object* object) {
    _object = object;
  }

 private:
  Process* _process;

  // Object to notify.
  Object* _object;

  ObjectNotifyMessage* _message;

  // Garbage collection support.
  void roots_do(RootCallback* cb);

  friend class ObjectHeap;
};

class HeapRoot;
typedef DoubleLinkedList<HeapRoot> HeapRootList;
class HeapRoot : public HeapRootList::Element {
 public:
  explicit HeapRoot(Object* obj) : _obj(obj) {}

  Object* operator*() const { return _obj; }
  Object* operator->() const { return _obj; }
  void operator=(Object* obj) { _obj = obj; }

  Object** slot() { return &_obj; }
  void unlink() { HeapRootList::Element::unlink(); }

 private:
  Object* _obj;
};

// An object heap contains all objects created at runtime.
class ObjectHeap final : public Heap {
 public:
  ObjectHeap(Program* program, Process* owner, Block* initial_block);
  ~ObjectHeap();

  // Returns the number of bytes allocated in this heap.
  virtual int payload_size();

  Task* allocate_task();
  Stack* allocate_stack(int length);
  // Convenience methods for allocating proxy like objects.
  ByteArray* allocate_proxy(int length, uint8* memory, bool dispose = false) {
    return allocate_external_byte_array(length, memory, dispose, false);
  }
  ByteArray* allocate_proxy() { return allocate_proxy(0, null); }

  void print(Printer* printer);

  Object** global_variables() const { return _global_variables; }
  Task* task() { return _task; }
  void set_task(Task* task) { ASSERT(task->owner() == owner()); _task = task; }

  Method hatch_method() { return _hatch_method; }
  void set_hatch_method(Method method) { _hatch_method = method; }

  HeapObject* hatch_arguments() { return _hatch_arguments; }
  void set_hatch_arguments(HeapObject* array) { _hatch_arguments = array; }

  // Garbage collection operation for runtime objects.
  int scavenge();

  bool add_finalizer(HeapObject* key, Object* lambda);
  bool has_finalizer(HeapObject* key, Object* lambda);
  bool remove_finalizer(HeapObject* key);

  bool add_vm_finalizer(HeapObject* key);
  bool remove_vm_finalizer(HeapObject* key);

  Object* next_finalizer_to_run();
  void set_finalizer_notifier(ObjectNotifier* notifier);

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

 private:
  // An estimate of how much memory overhead malloc has.
  static const word _EXTERNAL_MEMORY_ALLOCATOR_OVERHEAD = 2 * sizeof(word);

  // Minimum number of heap blocks we limit ourselves to.
  static const word _MIN_BLOCK_LIMIT = 4;

  // Number of bytes used before forcing a scavenge, including external memory.
  // Set to zero to have no limit.
  word _limit;
  // This limit will be installed at the end of the current primitive
  word _pending_limit;
  word _max_heap_size;  // Configured max heap size, incl. external allocation.
  std::atomic<word> _external_memory;  // In bytes.
  Task* _task;
  Method _hatch_method;
  HeapObject* _hatch_arguments;
  ObjectNotifierList _object_notifiers;

  // A finalizer is in one of the following lists.
  FinalizerNodeFIFO _registered_finalizers;  // Contains registered finalizers.
  FinalizerNodeFIFO _runnable_finalizers; // Contains finalizers that must be executed.
  VMFinalizerNodeFIFO _registered_vm_finalizers;  // Contains registered VM finalizers.
  ObjectNotifier* _finalizer_notifier;

  int _gc_count;
  Object** _global_variables;

  Object** _copy_global_variables();

  HeapRootList _external_roots;

  // Calculate the memory limit for scavenge based on the number of live blocks
  // and the externally allocated memory.
  word _calculate_limit();
  AllocationResult _expand();

  friend class ObjectNotifier;
};

} // namespace toit
