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
    PRINT_STACK_TRACE = 1 << 1,
    PREEMPT           = 1 << 2,
    WATCHDOG          = 1 << 3,
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

  Process(Program* program, ProcessGroup* group, SystemMessage* termination, char** args, InitialMemory* initial_memory);
#ifndef TOIT_FREERTOS
  Process(Program* program, ProcessGroup* group, SystemMessage* termination, SnapshotBundle bundle, char** args, InitialMemory* initial_memory);
#endif
  Process(Program* program, ProcessGroup* group, SystemMessage* termination, Method method, uint8* arguments, InitialMemory* initial_memory);
  ~Process();

  // Constructor for an external process (no Toit code).
  Process(ProcessRunner* runner, ProcessGroup* group, SystemMessage* termination);

  int id() const { return _id; }
  int next_task_id() { return _next_task_id++; }

  bool is_suspended() const { return _state == SUSPENDED_IDLE || _state == SUSPENDED_SCHEDULED; }

  // Returns whether this process is privileged (a system process).
  bool is_privileged() const { return _is_privileged; }
  void mark_as_priviliged() { _is_privileged = true; }

  // Garbage collection operation for runtime objects.
  int gc() {
    if (program() == null) return 0;
    int result = object_heap()->gc();
    _memory_usage = object_heap()->usage("object heap after gc");
    return result;
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
  Usage* usage() { return &_memory_usage; }
  Task* task() { return object_heap()->task(); }

  ProcessRunner* runner() const { return _runner; }

  void print();

  Method entry() const { return _entry; }
  char** args() { return _args; }
  Method hatch_method() const { return _hatch_method; }
  uint8* hatch_arguments() const { return _hatch_arguments; }
  void clear_hatch_arguments() { _hatch_arguments = null; }

  // Handling of messages and completions.
  bool has_messages();
  Message* peek_message();
  void remove_first_message();
  int message_count();

  SystemMessage* take_termination_message(uint8 result);

  // Signals that a message is for this process.
  void send_mail(Message* message);

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
  int gc_count() { return _object_heap.gc_count(); }

  // Special allocation of byte arrays and strings due to multiple reasons for failure.
  // The error string is only set if null is returned.
  String* allocate_string(const char* content, Error** error);
  String* allocate_string(int length, Error** error);
  String* allocate_string(const char* content, int length, Error** error);
  Object* allocate_string_or_error(const char* content);
  Object* allocate_string_or_error(const char* content, int length);
  ByteArray* allocate_byte_array(int length, Error** error, bool force_external=false);

#ifdef LEGACY_GC
  word number_of_blocks() {
    return _object_heap.number_of_blocks();
  }
#endif

  void set_max_heap_size(word bytes) {
    _object_heap.set_max_heap_size(bytes);
  }

  bool should_allow_external_allocation(word size) {
    bool result = _object_heap.should_allow_external_allocation(size);
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

  #ifdef PROFILER
   int install_profiler(int task_id) {
     ASSERT(profiler() == null);
     _profiler = _new Profiler(task_id);
     if (_profiler == null) return -1;
     return profiler()->allocated_bytes();
   }
   Profiler* profiler() { return _profiler; }
   void uninstall_profiler() {
     Profiler* p = profiler();
     _profiler = null;
     delete p;
   }
  #endif

  void set_last_run(int64 us) {
    _last_run_us = us;
  }

  void increment_unyielded_for(int64 us) {
    _unyielded_for_us += us;
  }

  void clear_unyielded_for() {
    _unyielded_for_us = 0;
  }

  int64 current_run_duration(int64 now) {
    return _unyielded_for_us + (now - _last_run_us);
  }

  inline bool on_program_heap(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    return address - _program_heap_address < _program_heap_size;
  }

 private:
  Process(Program* program, ProcessRunner* runner, ProcessGroup* group, SystemMessage* termination, InitialMemory* initial_memory);
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
  char** _args;

  Method _hatch_method;
  uint8* _hatch_arguments;

  ObjectHeap _object_heap;
  Usage _memory_usage;
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

  int64 _last_run_us = 0;
  int64 _unyielded_for_us = 0;

#ifdef PROFILER
  Profiler* _profiler = null;
#endif

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
    , _process(process)
    , _hit_limit(false) {}

  AllocationManager(Process* process, void* ptr, word size)
    : _ptr(ptr)
    , _size(size)
    , _process(process)
    , _hit_limit(false) {
    process->register_external_allocation(size);
  }

  uint8_t* alloc(word length) {
    ASSERT(_ptr == null);
    if (!_process->should_allow_external_allocation(length)) {
      _hit_limit = true;
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
  bool _hit_limit;
};

} // namespace toit
