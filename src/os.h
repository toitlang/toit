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
#include "mutex.h"

namespace toit {

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

  void cancel();
  void join();

 protected:
  virtual void entry() = 0;

 private:
  void _boot();

  const char* name_;
  void* handle_;
  Locker* locker_;

  friend void* thread_start(void*);
  friend class Locker;
};

class SystemThread : public Thread {
 public:
  SystemThread() : Thread("System") {}

 protected:
  void entry() {}
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
      : memory_(size_in_bytes, compute_alignment(alignment)) {}
  virtual ~ProtectableAlignedMemory();

  // Returns the aligned address.
  virtual void* address() { return memory_.address(); }
  virtual size_t byte_size() const { return memory_.byte_size(); }

  void mark_read_only();

 private:
  AlignedMemory memory_;
  static size_t compute_alignment(size_t alignment);
};
#endif

class OS {
 public:
  // Returns the number of microseconds from the first get_monotonic_time call.
  static int64 get_monotonic_time();
  static void reset_monotonic_time();

  /// Computes the executable path.
  ///
  /// Returns a malloced data structure that should be freed
  ///   by the caller with `delete []`.
  static char* get_executable_path();

  /// Computes the executable path of a source argument.
  /// This is equivalent to calling `realpath`/`GetFullPathName` on the argument.
  /// Returns 'null' if anything goes wrong.
  /// Returns a malloced data structure that should be freed.
  static char* get_executable_path_from_arg(const char* source_arg);

  // Returns the number of microseconds from the last power-on event. This time
  // source is monotonic.
  static int64 get_system_time();

  // Fills in the given timespec with the current time.
  static bool get_real_time(struct timespec* time);
  static bool set_real_time(struct timespec* time);

  // Return the number of cores available on the system.
  static int num_cores();

  static void out_of_memory(const char* reason);

  static Mutex* global_mutex() { return global_mutex_; }
  static Mutex* tls_mutex() { return tls_mutex_; }
  static Mutex* process_mutex() { return process_mutex_; }
  static Mutex* resource_mutex() { return resource_mutex_; }

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
  static bool wait_us(ConditionVariable* condition_variable, int64 us);
  static void signal(ConditionVariable* condition_variable);
  static void signal_all(ConditionVariable* condition_variable);
  static void dispose(ConditionVariable* condition_variable);

  static void close(int fd);

  // Grab-vm reserves the virtual address range.  If the address is non-null
  // then the system takes it as a preferred address, but may pick a different
  // address address.  The address grabbed is returned.
  // On a system without virtual memory this is just a malloc.  The size
  // is rounded up to the page size on systems with virtual memory.
  static void* grab_virtual_memory(void* address, uword size);
  static void ungrab_virtual_memory(void* address, uword size);
  // Use-vm makes the virtual address range usable (adds read-write permissions).
  // Does nothing on a system without virtual memory.
  static bool use_virtual_memory(void* address, uword size);
  // Unuse-vm makes the virtual address range unusable (no read-write permissions),
  // which frees up the memory, returning it to the OS.  The virtual address range
  // is still reserved though.
  // Does nothing on a system without virtual memory.
  static void unuse_virtual_memory(void* address, uword size);

  struct HeapMemoryRange {
    void* address;
    uword size;
  };

  // Inform the GC about the memory map so it knows where to expect allocations
  // to happen.
  static HeapMemoryRange get_heap_memory_range();

  // Allocate/free some pages of memory.  They will be within the range
  // returned by get_heap_memory_range.
  static void* allocate_pages(uword size);
  static void free_pages(void* address, uword size);

  static Block* allocate_block();
  static void free_block(Block* block);
  static void free_block(ProgramBlock* block);
  static void set_writable(ProgramBlock* block, bool value);

  static void set_up();
  static void tear_down();
  static const char* get_platform();
  static const char* get_architecture();

  static int read_entire_file(char* name, uint8** buffer);

  // If we are using Cmpctmalloc this lets us set a tag that is used to mark
  // the origin of allocations on the current thread.
  static void set_heap_tag(word tag);
  static word get_heap_tag();
  static void heap_summary_report(int max_pages, const char* marker, Process* process);

  // Returns a malloced string.
  static char* getenv(const char* variable);
  // Returns true for OK.
  static bool setenv(const char* variable, const char* value);
  static bool unsetenv(const char* variable);

#ifdef TOIT_ESP32
  static bool use_spiram_for_heap() { return use_spiram_for_heap_; }
  static bool use_spiram_for_metadata() { return use_spiram_for_metadata_; }
  static int toit_heap_caps_flags_for_heap();
  static int toit_heap_caps_flags_for_metadata();
#elif defined(TOIT_LINUX)
  static inline int toit_heap_caps_flags_for_heap() { return 0; }
#endif

 private:
  static void set_up_mutexes();
  static void tear_down_mutexes();

  static bool monotonic_gettime(int64* timestamp);
  static void timespec_increment(timespec* ts, int64 ns);

  static Mutex* global_mutex_;
  static Mutex* tls_mutex_;
  static Mutex* process_mutex_;
  static Mutex* resource_mutex_;
  static HeapMemoryRange single_range_;
  static int cpu_revision_;
#ifdef TOIT_ESP32
  static bool use_spiram_for_heap_;
  static bool use_spiram_for_metadata_;
#endif

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
  void heap_caps_iterate_tagged_memory_areas(void*, void*, heap_caps_iterate_callback, int) __attribute__ ((weak));
  void heap_caps_set_option(int, void*) __attribute__ ((weak));
}
#endif
