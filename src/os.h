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

#include <time.h>

#include "top.h"

namespace toit {

// Stack allocated block structured operation for locking and unlocking a mutex.
// Usage:
//  { Locker l(mutex);
//    .. mutex is locked until end of scope ...
//  }
class Locker {
 public:
  explicit Locker(Mutex* mutex)  : _mutex(mutex), _previous(null) {
    enter();
  }
  ~Locker() {
    leave();
  }

 private:
  // Explicitly leave the locker, while in the scope. Must be re-entered by
  // calling `enter`.
  void leave();

  // Enter a locker after leaving it.
  void enter();

  Mutex* _mutex;
  Locker* _previous;

  friend class Unlocker;
};

// Block structured operation for temporarily unlocking a mutex inside a Locker.
// Usage:
//  { Unlocker u(locker);
//    .. mutex is unlocked until end of scope ...
//  }
class Unlocker {
 public:
  explicit Unlocker(Locker& locker) : _locker(locker) {
    _locker.leave();
  }
  ~Unlocker() {
    _locker.enter();
  }

 private:
  Locker& _locker;
};


// Abstraction for running stuff in parallel.
class Thread {
 public:
  explicit Thread(const char* name);
  virtual ~Thread() {}

  static Thread* current();

  // Ensure a SystemThread has been assigned to the running thread.
  // This will guarantee Thread::current() will return non-null
  // and proper mutex checks with take place.
  static void ensure_system_thread();

  // Returns true for success, false for malloc failure.
  bool spawn(int stack_size = 0, int core = -1);
  void run();  // Run on current thread.

  void join();

 protected:
  virtual void entry() = 0;

 private:
  void _boot();

  const char* _name;
  void* _handle;
  Locker* _locker;

  friend void* thread_start(void*);
  friend class Locker;
};

class SystemThread : public Thread {
 public:
  SystemThread() : Thread("System") {}

 protected:
  void entry() {}
};

class PagedMemoryBlock;

class PagedMemory {
 public:
  explicit PagedMemory();
  ~PagedMemory();

  // Allocate a block of memory that is guaranteed to be page aligned.
  void* allocate_pages(int& byte_size);

 private:
  PagedMemoryBlock* _block;
};

class AlignedMemoryBase {
 public:
  virtual ~AlignedMemoryBase();

  // Returns the aligned address.
  virtual void* address() = 0;
  virtual size_t byte_size() const = 0;
};

// Class used for allocating aligned C heap memory.
class AlignedMemory : public AlignedMemoryBase {
 public:
  AlignedMemory(size_t size_in_bytes, size_t alignment);
  virtual ~AlignedMemory();

  // Returns the aligned address.
  virtual void* address() { return aligned; }
  virtual size_t byte_size() const { return size_in_bytes; }

 private:
  const size_t size_in_bytes;
  void* raw;
  void* aligned;
};

#ifndef TOIT_FREERTOS
class ProtectableAlignedMemory : public AlignedMemoryBase {
 public:
  ProtectableAlignedMemory(size_t size_in_bytes, size_t alignment)
      : _memory(size_in_bytes, compute_alignment(alignment)) { }
  virtual ~ProtectableAlignedMemory();

  // Returns the aligned address.
  virtual void* address() { return _memory.address(); }
  virtual size_t byte_size() const { return _memory.byte_size(); }

  void mark_read_only();

 private:
  AlignedMemory _memory;
  static size_t compute_alignment(size_t alignment);
};
#endif

class OS {
 public:
  // Returns the number of microseconds from the first get_monotonic_time call.
  static int64 get_monotonic_time();
  static void reset_monotonic_time();

  // Returns the number of microseconds from the last power-on event. This time
  // source is monotonic.
  static int64 get_system_time();

  // Fills in the given timespec with the current time.
  static bool get_real_time(struct timespec* time);
  static bool set_real_time(struct timespec* time);

  // Return the number of cores available on the system.
  static int num_cores();

  static void out_of_memory(const char* reason);

  static Mutex* global_mutex() { return _global_mutex; }
  static Mutex* scheduler_mutex() { return _scheduler_mutex; }

  // Mutex (used with Locker).
  static Mutex* allocate_mutex(int level, const char* title);
  static void dispose(Mutex* mutex);
  static bool is_locked(Mutex* mutex);  // For asserts.
  // Use this when the scoped Locker object is not appropriate.
  static void lock(Mutex* mutex);
  static void unlock(Mutex* mutex);

  // Condition variable.
  static ConditionVariable* allocate_condition_variable(Mutex* mutex);
  static void wait(ConditionVariable* condition_variable);
  // Returns false if a timeout occurs.
  static bool wait(ConditionVariable* condition_variable, int timeout_in_ms);
  static void signal(ConditionVariable* condition_variable);
  static void signal_all(ConditionVariable* condition_variable);
  static void dispose(ConditionVariable* condition_variable);

  static void close(int fd);

  static Block* allocate_block();
  static ProgramBlock* allocate_program_block();
  static void free_block(Block* block);
  static void free_block(ProgramBlock* block);
  static void set_writable(Block* block, bool value);
  static void set_writable(ProgramBlock* block, bool value);

  static void set_up();
  static void tear_down();
  static const char* get_platform();

  static int read_entire_file(char* name, uint8** buffer);

  // If we are using Cmpctmalloc this lets us set a tag that is used to mark
  // the origin of allocations on the current thread.
  static void set_heap_tag(word tag);
  static word get_heap_tag();
  static void heap_summary_report(int max_pages, const char* marker);

  // Unique 16-bytes uuid of the running image.
  static const uint8* image_uuid();

  // ubjson-encoded configuration of the running image. Return NULL if not found.
  static uint8* image_config(size_t *length);

  static const char* getenv(const char* variable);

 private:
  static bool monotonic_gettime(int64* timestamp);
  static void timespec_increment(timespec* ts, int64 ns);

  static Mutex* _global_mutex;
  static Mutex* _scheduler_mutex;

  friend class ConditionVariable;
};

class HeapTagScope {
 public:
  HeapTagScope(uword tag) {
    old = OS::get_heap_tag();
    OS::set_heap_tag(tag);
  }

  ~HeapTagScope() {
    OS::set_heap_tag(old);
  }

  uword old;
};

} // namespace toit

#ifdef TOIT_LINUX
// Weak symbols for the custom heap.  These are only present on non-embedded
// platforms if we are using LD_PRELOAD to replace the malloc implementation.
extern "C" {
typedef bool heap_caps_iterate_callback(void*, void*, void*, size_t);
__attribute__ ((weak)) extern void heap_caps_iterate_tagged_memory_areas(void*, void*, heap_caps_iterate_callback, int);
__attribute__ ((weak)) extern void heap_caps_set_option(int, void*);
}
#endif
