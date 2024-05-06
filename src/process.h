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

class UnparsedRootCertificate;
typedef LinkedFifo<UnparsedRootCertificate> UnparsedRootCertificateList;

class UnparsedRootCertificate: public UnparsedRootCertificateList::Element {
 public:
  UnparsedRootCertificate(const uint8* data, size_t length, bool needs_delete);
  ~UnparsedRootCertificate();
  bool matches(const uint8* data, size_t length) const;

  const uint8* data() const { return data_; }
  size_t length() const { return length_; }

  void set_subject_hash(uint32 hash) { subject_hash_ = hash; }
  uint32 subject_hash() const { return subject_hash_; }

 private:
  const uint8* data_;
  size_t length_;
  uint32 subject_hash_ = 0;
  bool needs_delete_;
};

// Process is linked into two different linked lists, so we have to make
// use of the arbitrary N template argument to distinguish the two.
typedef LinkedList<Process, 1> ProcessListFromProcessGroup;
typedef LinkedFifo<Process, 2> ProcessListFromScheduler;

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

  // Should match the constants in lib/core/process.toit.
  static const uint8 PRIORITY_IDLE     = 0;
  static const uint8 PRIORITY_LOW      = 43;
  static const uint8 PRIORITY_NORMAL   = 128;
  static const uint8 PRIORITY_HIGH     = 213;
  static const uint8 PRIORITY_CRITICAL = 255;

  static const char* StateName[];

  // Constructor for an internal process based on Toit code.
  Process(Program* program, ProcessGroup* group, SystemMessage* termination, InitialMemoryManager* initial_memory);

  // Constructor for an internal process spawned from Toit code.
  Process(Program* program, ProcessGroup* group, SystemMessage* termination, Method method, InitialMemoryManager* initial_memory);

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

  int id() const { return id_; }
  int next_task_id() { return next_task_id_++; }

  bool is_suspended() const { return state_ == SUSPENDED_IDLE || state_ == SUSPENDED_SCHEDULED; }

  // Returns whether this process is privileged (a system process).
  bool is_privileged() const { return is_privileged_; }
  void mark_as_priviliged() { is_privileged_ = true; }

  // Garbage collection operation for runtime objects.
  GcType gc(bool try_hard) {
    ASSERT(program() != null);  // Should not call GC on external processes.
    return object_heap()->gc(try_hard);
  }

  bool idle_since_gc() const { return idle_since_gc_; }
  void set_idle_since_gc(bool value) { idle_since_gc_ = value; }

  Program* program() { return program_; }
  ProcessGroup* group() { return group_; }
  ObjectHeap* object_heap() { return &object_heap_; }
  Task* task() { return object_heap()->task(); }

  ProcessRunner* runner() const { return runner_; }

  Method entry() const { return entry_; }
  uint8* main_arguments() { return main_arguments_; }
  void clear_main_arguments() { main_arguments_ = null; }

  Method spawn_method() const { return spawn_method_; }
  uint8* spawn_arguments() const { return spawn_arguments_; }
  void clear_spawn_arguments() { spawn_arguments_ = null; }

  // Handling of messages and completions.
  bool has_messages();
  Message* peek_message();
  void remove_first_message();
  int message_count();

  SystemMessage* take_termination_message(uint8 result);

  uint64 random();
  void random_seed(const uint8* buffer, size_t size);

  State state() { return state_; }
  void set_state(State state) { state_ = state; }

  void add_resource_group(ResourceGroup* r);
  void remove_resource_group(ResourceGroup* r);

  SchedulerThread* scheduler_thread() { return scheduler_thread_; }
  void set_scheduler_thread(SchedulerThread* scheduler_thread) {
    scheduler_thread_ = scheduler_thread;
  }

  void signal(Signal signal);
  void clear_signal(Signal signal);
  uint32 signals() const { return signals_; }

  // Processes have a priority in the range [0..255]. The scheduler
  // prioritizes running processes with higher priorities, so processes
  // with lower priorities might get starved by more important things.
  uint8 priority() const { return priority_; }

  // The scheduler needs to be in charge of updating priorities,
  // because it might have a process in queue determined by the
  // current priority and it needs to be able to find it there
  // again. Once a process is ready to run, the scheduler will
  // update the priority and make the target priority the current
  // priority.
  void set_target_priority(uint8 value) { target_priority_ = value; }
  uint8 update_priority();

  // TODO(mikkel): current_directory could be a union with an int and a char*. The clients of this member would know
  //               which field to access.
#if defined(TOIT_WINDOWS)
  const wchar_t* current_directory();
  void set_current_directory(const wchar_t* current_directory);
#else
  int current_directory() { return current_directory_; }
  void set_current_directory(int fd) { current_directory_ = fd; }
#endif
  int gc_count(GcType type) { return object_heap_.gc_count(type); }

  String* allocate_string(const char* content);
  String* allocate_string(word length);
  String* allocate_string(const char* content, word length);
  Object* allocate_string_or_error(const char* content);
  Object* allocate_string_or_error(const char* content, word length);
#if defined(TOIT_WINDOWS)
  String* allocate_string(const wchar_t* content);
  String* allocate_string(const wchar_t* content, word length);
#endif
  ByteArray* allocate_byte_array(word length, bool force_external=false);

  void set_max_heap_size(word bytes) {
    object_heap_.set_max_heap_size(bytes);
  }

  bool should_allow_external_allocation(word size) {
    word max = object_heap_.max_external_allocation();
    bool result = max >= size;
    object_heap_.set_last_allocation_result(result ? ObjectHeap::ALLOCATION_SUCCESS : ObjectHeap::ALLOCATION_HIT_LIMIT);
    return result;
  }

  bool system_refused_memory() const {
    return object_heap_.system_refused_memory();
  }

  void register_external_allocation(word size) {
    object_heap_.register_external_allocation(size);
  }

  void unregister_external_allocation(word size) {
    object_heap_.unregister_external_allocation(size);
  }

  int64 bytes_allocated_delta() {
    int64 current = object_heap()->total_bytes_allocated();
    int64 result = current - last_bytes_allocated_;
    last_bytes_allocated_ = current;
    return result;
  }

  Profiler* profiler() const { return profiler_; }

  int install_profiler(int task_id) {
    ASSERT(profiler() == null);
    profiler_ = _new Profiler(task_id);
    if (profiler_ == null) return -1;
    return profiler()->allocated_bytes();
  }

  void uninstall_profiler() {
    Profiler* p = profiler();
    profiler_ = null;
    delete p;
  }

  inline bool on_program_heap(const HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    return address - program_heap_address_ < program_heap_size_;
  }

  inline HeapObject* false_object() const { return false_object_; }
  inline HeapObject* true_object() const { return true_object_; }
  inline HeapObject* null_object() const { return null_; }

  // These root certificate functions should be guarded by the TLS mutex.
  void add_root_certificate(UnparsedRootCertificate* certificate, const Locker& locker) {
    root_certificates_.append(certificate);
  }

  bool already_has_root_certificate(const uint8* data, size_t length, const Locker& locker);

  UnparsedRootCertificateList& root_certificates(const Locker& locker) {
    return root_certificates_;
  }

  // Sets the timestamp for when this process just started running.
  void set_run_timestamp(int64 timestamp) {
    ASSERT(state_ == RUNNING);
    ASSERT(timestamp >= 0);
    run_timestamp_ = timestamp;
  }

  // Clears the timestamp, so the process will not appear to have
  // been running for any time at all.
  void clear_run_timestamp() {
    ASSERT(state_ == RUNNING);
    run_timestamp_ = -1;
  }

  int64 run_time_us(int64 now) const {
    ASSERT(now >= 0);
    int64 timestamp = run_timestamp_;
    ASSERT(state_ == RUNNING || timestamp < 0);
    return timestamp < 0 ? 0 : (now - timestamp);
  }

  // Sets the current BCP variable.
  // We use this variable for bytecodes that could potentially hang, so we can
  // detect if a process is stuck.
  void set_current_bcp(uint8* bcp) {
    current_bcp_ = bcp;
  }

  uint8* current_bcp() const {
    return current_bcp_;
  }

 private:
  Process(Program* program, ProcessRunner* runner, ProcessGroup* group, SystemMessage* termination, InitialMemoryManager* initial_memory);
  void _append_message(Message* message);
  void _ensure_random_seeded();

  int const id_;
  int next_task_id_;
  bool is_privileged_ = false;

  Program* program_;
  ProcessRunner* runner_;
  ProcessGroup* group_;

  uint8 priority_ = PRIORITY_NORMAL;
  uint8 target_priority_ = PRIORITY_NORMAL;

  uword program_heap_address_;
  uword program_heap_size_;

  Method entry_;
  Method spawn_method_;

  // The arguments (if any) are encoded as messages using the MessageEncoder.
  uint8* main_arguments_ = null;
  uint8* spawn_arguments_ = null;

  ObjectHeap object_heap_;
  int64 last_bytes_allocated_;

  MessageFIFO messages_;

  SystemMessage* termination_message_;

  bool random_seeded_;
  uint64 random_state0_;
  uint64 random_state1_;

#if defined(TOIT_WINDOWS)
  const wchar_t* current_directory_;
#else
  int current_directory_;
#endif

  uint32_t signals_;
  State state_;
  SchedulerThread* scheduler_thread_;

  bool construction_failed_ = false;
  bool idle_since_gc_ = true;

  UnparsedRootCertificateList root_certificates_;

  Profiler* profiler_ = null;

  HeapObject* false_object_;
  HeapObject* true_object_;
  HeapObject* null_;

  ResourceGroupListFromProcess resource_groups_;

  int64 run_timestamp_ = -1;
  uint8* current_bcp_ = null;

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
    : ptr_(null)
    , size_(0)
    , process_(process) {}

  template<typename T>
  AllocationManager(Process* process, T* ptr, word size=0)
    : ptr_(void_cast(ptr))
    , size_(size)
    , process_(process) {
    process->register_external_allocation(size);
  }

  // Normally we would trigger a GC if too much is allocated externally, but on
  // desktop systems we sometimes want to be allowed to allocate without
  // worrying about triggering a GC in a complicated primitiive.
  void set_always_allow_external() {
    always_allow_external_ = true;
  }

  uint8* alloc(word length) {
    ASSERT(ptr_ == null);
    bool ok = always_allow_external_ || process_->should_allow_external_allocation(length);
    if (!ok) {
      return null;
    }
    // Don't change this to use C++ array 'new' because that isn't compatible
    // with realloc.
    ptr_ = malloc(length);
    if (ptr_ == null) {
      process_->object_heap()->set_last_allocation_result(ObjectHeap::ALLOCATION_OUT_OF_MEMORY);
    } else {
      process_->register_external_allocation(length);
      size_ = length;
    }

    return unvoid_cast<uint8*>(ptr_);
  }

  static uint8* reallocate(uint8* old_allocation, word new_size) {
    return unvoid_cast<uint8*>(::realloc(old_allocation, new_size));
  }

  uint8* calloc(word length, word size) {
    uint8* allocation = alloc(length * size);
    if (allocation != null) {
      ASSERT(size_ == length * size);
      memset(allocation, 0, size_);
    }
    return allocation;
  }

  ~AllocationManager() {
    if (ptr_ != null) {
      free(ptr_);
      process_->unregister_external_allocation(size_);
    }
  }

  uint8* keep_result() {
    void* result = ptr_;
    ptr_ = null;
    return unvoid_cast<uint8*>(result);
  }

 protected:
  void* ptr_;

 private:
  word size_;
  Process* process_;
  bool always_allow_external_ = false;
};

#ifdef TOIT_WINDOWS

class WideCharAllocationManager : public AllocationManager {
 public:
  WideCharAllocationManager(Process* process) : AllocationManager(process) {
    set_always_allow_external();
  }

  inline wchar_t* to_wcs(Blob* blob, word* length_return = null) {
    word utf_16_length = Utils::utf_8_to_16(blob->address(), blob->length());
    auto utf_16_string = unvoid_cast<uint16*>(this->calloc(utf_16_length + 1, sizeof(uint16)));
    Utils::utf_8_to_16(blob->address(), blob->length(), utf_16_string, utf_16_length);
    utf_16_string[utf_16_length] = 0;
    if (length_return) *length_return = utf_16_length;
    return reinterpret_cast<wchar_t*>(utf_16_string);
  }

  wchar_t* wcs_alloc(word length) {
    ASSERT(ptr_ == null);
    if (length <= INTERNAL_BUFFER_SIZE) {
      return buffer_;
    }
    return reinterpret_cast<wchar_t*>(alloc(length * sizeof(wchar_t)));
  }

 private:
  static const int INTERNAL_BUFFER_SIZE = 260;
  wchar_t buffer_[INTERNAL_BUFFER_SIZE];
};

#endif

} // namespace toit
