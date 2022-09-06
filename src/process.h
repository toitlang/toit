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

#include "heap.h"
#include "interpreter.h"
#include "linked.h"
#include "messaging.h"
#include "profiler.h"
#include "resource.h"
#include "snapshot_bundle.h"

namespace toit {

// Process is linked into two different linked lists, so we have to make
// use of the arbitrary N template argument to distinguish the two.
typedef LinkedList<Process, 1> ProcessListFromProcessGroup;
typedef LinkedFIFO<Process, 2> ProcessListFromScheduler;

class Process : public ProcessListFromProcessGroup::Element,
                public ProcessListFromScheduler::Element {
 public:
  enum Signal {
    KILL              = 1 << 0,
    PREEMPT           = 1 << 1,
  };

  enum State {
    IDLE,
    SCHEDULED,
    RUNNING,
    TERMINATING,

    SUSPENDED_IDLE,
    SUSPENDED_SCHEDULED,
    SUSPENDED_AWAITING_GC
  };

  static const char* StateName[];

  // Constructor for an internal process based on Toit code.
  Process(Program* program, ProcessGroup* group, SystemMessage* termination, Chunk* initial_chunk);

  // Constructor for an internal process spawned from Toit code.
  Process(Program* program, ProcessGroup* group, SystemMessage* termination, Method method, Chunk* initial_chunk);

  // Constructor for an external process with no Toit code.
  Process(ProcessRunner* runner, ProcessGroup* group, SystemMessage* termination);

  // Construction support.
  void set_main_arguments(uint8* arguments);
  void set_spawn_arguments(uint8* arguments);
#ifndef TOIT_FREERTOS
  void set_main_arguments(char** argv);
  void set_spawn_arguments(SnapshotBundle system, SnapshotBundle application);
#endif

  ~Process();

  int id() const { return _id; }
  int next_task_id() { return _next_task_id++; }

  bool is_suspended() const { return _state == SUSPENDED_IDLE || _state == SUSPENDED_SCHEDULED; }

  // Returns whether this process is privileged (a system process).
  bool is_privileged() const { return _is_privileged; }
  void mark_as_priviliged() { _is_privileged = true; }

  // Garbage collection operation for runtime objects.
  void gc(bool try_hard) {
    if (program() == null) return;
    object_heap()->gc(try_hard);
  }

  bool idle_since_gc() const { return _idle_since_gc; }
  void set_idle_since_gc(bool value) { _idle_since_gc = value; }

  bool has_finalizer(HeapObject* key, Object* lambda) {
    return object_heap()->has_finalizer(key, lambda);
  }
  bool add_finalizer(HeapObject* key, Object* lambda) {
    return object_heap()->add_finalizer(key, lambda);
  }
  bool add_vm_finalizer(HeapObject* key) {
    return object_heap()->add_vm_finalizer(key);
  }
  bool remove_finalizer(HeapObject* key) {
    return object_heap()->remove_finalizer(key);
  }

  Object* next_finalizer_to_run() {
    return object_heap()->next_finalizer_to_run();
  }

  Program* program() { return _program; }
  ProcessGroup* group() { return _group; }
  ObjectHeap* object_heap() { return &_object_heap; }
  Task* task() { return object_heap()->task(); }

  ProcessRunner* runner() const { return _runner; }

  Method entry() const { return _entry; }
  uint8* main_arguments() { return _main_arguments; }
  void clear_main_arguments() { _main_arguments = null; }

  Method spawn_method() const { return _spawn_method; }
  uint8* spawn_arguments() const { return _spawn_arguments; }
  void clear_spawn_arguments() { _spawn_arguments = null; }

  // Handling of messages and completions.
  bool has_messages();
  Message* peek_message();
  void remove_first_message();
  int message_count();

  SystemMessage* take_termination_message(uint8 result);

  uint64_t random();
  void random_seed(const uint8_t* buffer, size_t size);

  State state() { return _state; }
  void set_state(State state) { _state = state; }

  void add_resource_group(ResourceGroup* r);
  void remove_resource_group(ResourceGroup* r);

  SchedulerThread* scheduler_thread() { return _scheduler_thread; }
  void set_scheduler_thread(SchedulerThread* scheduler_thread) {
    _scheduler_thread = scheduler_thread;
  }

  void signal(Signal signal);
  void clear_signal(Signal signal);
  uint32_t signals() const { return _signals; }

  int current_directory() { return _current_directory; }
  void set_current_directory(int fd) { _current_directory = fd; }
  int gc_count(GcType type) { return _object_heap.gc_count(type); }

  // Special allocation of byte arrays and strings due to multiple reasons for failure.
  // The error string is only set if null is returned.
  String* allocate_string(const char* content, Error** error);
  String* allocate_string(int length, Error** error);
  String* allocate_string(const char* content, int length, Error** error);
  Object* allocate_string_or_error(const char* content);
  Object* allocate_string_or_error(const char* content, int length);
  ByteArray* allocate_byte_array(int length, Error** error, bool force_external=false);

  void set_max_heap_size(word bytes) {
    _object_heap.set_max_heap_size(bytes);
  }

  bool should_allow_external_allocation(word size) {
    word max = _object_heap.max_external_allocation();
    bool result = max >= size;
    _object_heap.set_last_allocation_result(result ? ObjectHeap::ALLOCATION_SUCCESS : ObjectHeap::ALLOCATION_HIT_LIMIT);
    return result;
  }

  bool system_refused_memory() const {
    return _object_heap.system_refused_memory();
  }

  void register_external_allocation(word size) {
    _object_heap.register_external_allocation(size);
  }

  void unregister_external_allocation(word size) {
    _object_heap.unregister_external_allocation(size);
  }

  int64 bytes_allocated_delta() {
    int64 current = object_heap()->total_bytes_allocated();
    int64 result = current - _last_bytes_allocated;
    _last_bytes_allocated = current;
    return result;
  }

  Profiler* profiler() const { return _profiler; }

  int install_profiler(int task_id) {
    ASSERT(profiler() == null);
    _profiler = _new Profiler(task_id);
    if (_profiler == null) return -1;
    return profiler()->allocated_bytes();
  }

  void uninstall_profiler() {
    Profiler* p = profiler();
    _profiler = null;
    delete p;
  }

  inline bool on_program_heap(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    return address - _program_heap_address < _program_heap_size;
  }

 private:
  Process(Program* program, ProcessRunner* runner, ProcessGroup* group, SystemMessage* termination, Chunk* initial_chunk);
  void _append_message(Message* message);
  void _ensure_random_seeded();

  int const _id;
  int _next_task_id;
  bool _is_privileged = false;

  Program* _program;
  ProcessRunner* _runner;
  ProcessGroup* _group;

  uword _program_heap_address;
  uword _program_heap_size;

  Method _entry;
  Method _spawn_method;

  // The arguments (if any) are encoded as messages using the MessageEncoder.
  uint8* _main_arguments = null;
  uint8* _spawn_arguments = null;

  ObjectHeap _object_heap;
  int64 _last_bytes_allocated;

  MessageFIFO _messages;

  SystemMessage* _termination_message;

  bool _random_seeded;
  uint64_t _random_state0;
  uint64_t _random_state1;

  int _current_directory;

  uint32_t _signals;
  State _state;
  SchedulerThread* _scheduler_thread;

  bool _construction_failed = false;
  bool _idle_since_gc = true;

  Profiler* _profiler = null;

  ResourceGroupListFromProcess _resource_groups;
  friend class HeapObject;
  friend class Scheduler;
};

// A class to manage an allocation and its accounting in the external memory of
// the process.  When the object goes out of scope due to an error condition
// (early return) the allocation is freed and the accounting is updated to
// reflect that. When all conditions are checked and there will be no early
// return, call keep_result() on this object to disable its destructor.
class AllocationManager {
 public:
  explicit AllocationManager(Process* process)
    : _ptr(null)
    , _size(0)
    , _process(process) {}

  AllocationManager(Process* process, void* ptr, word size)
    : _ptr(ptr)
    , _size(size)
    , _process(process) {
    process->register_external_allocation(size);
  }

  uint8_t* alloc(word length) {
    ASSERT(_ptr == null);
    bool ok = _process->should_allow_external_allocation(length);
    if (!ok) {
      return null;
    }
    // Don't change this to use C++ array 'new' because that isn't compatible
    // with realloc.
    _ptr = malloc(length);
    if (_ptr == null) {
      _process->object_heap()->set_last_allocation_result(ObjectHeap::ALLOCATION_OUT_OF_MEMORY);
    } else {
      _process->register_external_allocation(length);
      _size = length;
    }

    return unvoid_cast<uint8_t*>(_ptr);
  }

  static uint8* reallocate(uint8* old_allocation, word new_size) {
    return unvoid_cast<uint8*>(::realloc(old_allocation, new_size));
  }

  uint8_t* calloc(word length, word size) {
    uint8_t* allocation = alloc(length * size);
    if (allocation != null) {
      ASSERT(_size == length * size);
      memset(allocation, 0, _size);
    }
    return allocation;
  }

  ~AllocationManager() {
    if (_ptr != null) {
      free(_ptr);
      _process->unregister_external_allocation(_size);
    }
  }

  uint8_t* keep_result() {
    void* result = _ptr;
    _ptr = null;
    return unvoid_cast<uint8_t*>(result);
  }

 private:
  void* _ptr;
  word _size;
  Process* _process;
};

} // namespace toit
