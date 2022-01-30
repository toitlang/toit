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

#include "top.h"

#ifdef TOIT_WINDOWS

#include "os.h"
#include "utils.h"
#include "uuid.h"
#include "memory.h"

#include <errno.h>
#include <pthread.h>
#include <sys/time.h>
#include <windows.h>

namespace toit {

int64 OS::get_system_time() {
  int64 us;
  if (!monotonic_gettime(&us)) {
    FATAL("failed getting system time");
  }
  return us;
}

class Mutex {
 public:
  Mutex(int level, const char* name)
    : _level(level) {
    pthread_mutex_init(&_mutex, null);
  }

  ~Mutex() {
    pthread_mutex_destroy(&_mutex);
  }

  void lock() {
    int error = pthread_mutex_lock(&_mutex);
    if (error != 0) FATAL("mutex lock failed with error %d", error);
  }

  void unlock() {
    int error = pthread_mutex_unlock(&_mutex);
    if (error != 0) FATAL("mutex unlock failed with error %d", error);
  }

  bool is_locked() {
    int error = pthread_mutex_trylock(&_mutex);
    if (error == 0) {
      unlock();
      return false;
    }
    if (error != EBUSY) FATAL("mutex trylock failed with error %d", error);
    return true;
  }

  int level() const { return _level; }

  int _level;
  pthread_mutex_t _mutex;
};

class ConditionVariable {
 public:
  explicit ConditionVariable(Mutex* mutex)
      : _mutex(mutex) {
    if (pthread_cond_init(&_cond, NULL) != 0) {
      FATAL("pthread_cond_init() error");
    }
  }

  ~ConditionVariable() {
    pthread_cond_destroy(&_cond);
  }

  void wait() {
    if (pthread_cond_wait(&_cond, &_mutex->_mutex) != 0) {
      FATAL("pthread_cond_timedwait() error");
    }
  }

  bool wait(int timeout_in_ms) {
    if (timeout_in_ms == 0) {
      // No timeout.
      wait();
      return true;
    }

    // TODO: We really should use monotonic time here.
    struct timespec deadline = { 0, };
    if (!OS::get_real_time(&deadline)) {
      FATAL("cannot get time for deadline");
    }
    OS::timespec_increment(&deadline, timeout_in_ms * 1000000LL);
    int error = pthread_cond_timedwait(&_cond, &_mutex->_mutex, &deadline);
    if (error == 0) return true;
    if (error == ETIMEDOUT) return false;
    FATAL("pthread_cond_timedwait() error: %d", error);
  }

  void signal() {
    if (!_mutex->is_locked()) {
      FATAL("signal on unlocked mutex");
    }
    int error = pthread_cond_signal(&_cond);
    if (error != 0) {
      FATAL("pthread_cond_signal() error: %d", error);
    }
  }

  void signal_all() {
    if (!_mutex->is_locked()) {
      FATAL("signal_all on unlocked mutex");
    }
    int error = pthread_cond_broadcast(&_cond);
    if (error != 0) {
      FATAL("pthread_cond_broadcast() error: %d", error);
    }
  }

 private:
  Mutex* _mutex;
  pthread_cond_t _cond;
};

void Locker::leave() {
  Thread* thread = Thread::current();
  if (thread->_locker != this) FATAL("unlocking would break lock order");
  thread->_locker = _previous;
  // Perform the actual unlock.
  _mutex->unlock();
}

void Locker::enter() {
  Thread* thread = Thread::current();
  int level = _mutex->level();
  Locker* previous_locker = thread->_locker;
  if (previous_locker != null) {
    int previous_level = previous_locker->_mutex->level();
    if (level <= previous_level) {
      FATAL("trying to take lock of level %d while holding lock of level %d", level, previous_level);
    }
  }
  // Lock after checking the precondition to avoid deadlocking
  // instead of just failing the precondition check.
  _mutex->lock();
  // Only update variables after we have the lock - that grants right
  // to update the locker.
  _previous = thread->_locker;
  thread->_locker = this;
}

static pthread_key_t thread_key;

static pthread_t pthread_from_handle(void* handle) {
  return reinterpret_cast<pthread_t>(handle);
}

Thread::Thread(const char* name)
    : _name(name)
    , _handle(null)
    , _locker(null) {
  USE(_name);
}

void* thread_start(void* arg) {
  Thread* thread = unvoid_cast<Thread*>(arg);
  thread->_boot();
  return null;
}

void Thread::_boot() {
  int result = pthread_setspecific(thread_key, void_cast(this));
  if (result != 0) FATAL("pthread_setspecific failed");
  ASSERT(current() == this);
  entry();
}

bool Thread::spawn(int stack_size, int core) {
  int result = pthread_create(reinterpret_cast<pthread_t*>(&_handle), null, &thread_start, void_cast(this));
  if (result != 0) {
    FATAL("pthread_create failed");
  }
  return true;
}

// Run on current thread.
void Thread::run() {
  ASSERT(_handle == null);
  thread_start(void_cast(this));
}

void Thread::join() {
  ASSERT(_handle != null);
  void* return_value;
  pthread_join(pthread_from_handle(_handle), &return_value);
}

void Thread::ensure_system_thread() {
  Thread* t = unvoid_cast<Thread*>(pthread_getspecific(thread_key));
  if (t != null) return;
  Thread* thread = _new SystemThread();
  if (thread == null) FATAL("unable to allocate SystemThread");
  int result = pthread_setspecific(thread_key, void_cast(thread));
  if (result != 0) FATAL("pthread_setspecific failed");
}

void OS::set_up() {
  ASSERT(sizeof(void*) == sizeof(pthread_t));
  (void) pthread_key_create(&thread_key, null);
  Thread::ensure_system_thread();
  _global_mutex = allocate_mutex(0, "Global mutex");
  _scheduler_mutex = allocate_mutex(4, "Scheduler mutex");
}

Thread* Thread::current() {
  Thread* result = unvoid_cast<Thread*>(pthread_getspecific(thread_key));
  if (result == null) FATAL("thread must be present");
  return result;
}

// Mutex forwarders.
Mutex* OS::allocate_mutex(int level, const char* title) { return _new Mutex(level, title); }
void OS::dispose(Mutex* mutex) { delete mutex; }
bool OS::is_locked(Mutex* mutex) { return mutex->is_locked(); }  // For asserts.
void OS::lock(Mutex* mutex) { mutex->lock(); }
void OS::unlock(Mutex* mutex) { mutex->unlock(); }

// Condition variable forwarders.
ConditionVariable* OS::allocate_condition_variable(Mutex* mutex) { return _new ConditionVariable(mutex); }
void OS::wait(ConditionVariable* condition_variable) { condition_variable->wait(); }
bool OS::wait(ConditionVariable* condition_variable, int timeout_in_ms) { return condition_variable->wait(timeout_in_ms); }
void OS::signal(ConditionVariable* condition_variable) { condition_variable->signal(); }
void OS::signal_all(ConditionVariable* condition_variable) { condition_variable->signal_all(); }
void OS::dispose(ConditionVariable* condition_variable) { delete condition_variable; }

void OS::close(int fd) {}

void OS::out_of_memory(const char* reason) {
  fprintf(stderr, "%s; aborting.\n", reason);
  abort();
}

const uint8* OS::image_uuid() {
  // Windows "devices" does not support images (ota, factory promote, factory reset) so the uuid
  // doesn't need to be unique.
  static uint8_t uuid[UUID_SIZE] = {0xe3, 0xbb, 0xa6, 0xa1, 0x23, 0x0c, 0x44, 0xa5, 0x9f, 0x5d, 0x09, 0x0c, 0xf7, 0xfd, 0x15, 0x2a};
  return uuid;
}

uint8* OS::image_config(size_t *length) {
  FATAL("should not be used on windows")
  return null;
}

const char* OS::getenv(const char* variable) {
  return ::getenv(variable);
}

bool OS::set_real_time(struct timespec* time) {
  FATAL("cannot set the time");
}

ProtectableAlignedMemory::~ProtectableAlignedMemory() {
}

void ProtectableAlignedMemory::mark_read_only() {
  // TODO(anders): Unimplemented.
}

size_t ProtectableAlignedMemory::compute_alignment(size_t alignment) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return Utils::max<size_t>(alignment, si.dwPageSize);
}

int OS::num_cores() {
  return 1;
}

void OS::free_block(Block* block) {
  _aligned_free(block);
}

void OS::free_block(ProgramBlock* block) {
  _aligned_free(block);
}

Block* OS::allocate_block() {
  void* result = _aligned_malloc(TOIT_PAGE_SIZE, TOIT_PAGE_SIZE);
  return (result == null) ? null : new (result) Block();
}

ProgramBlock* OS::allocate_program_block() {
  void* result = _aligned_malloc(TOIT_PAGE_SIZE, TOIT_PAGE_SIZE);
  return (result == null) ? null : new (result) ProgramBlock();
}

void OS::set_writable(ProgramBlock* block, bool value) {
  // TODO(anders): Unimplemented.
}

void OS::tear_down() {
  dispose(_global_mutex);
  dispose(_scheduler_mutex);
}

const char* OS::get_platform() {
  return "Windows";
}

int OS::read_entire_file(char* name, uint8** buffer) {
  FATAL("read_entire_file unimplemented");
}

void OS::set_heap_tag(word tag) {}

word OS::get_heap_tag() { return 0; }

void OS::heap_summary_report(int max_pages, const char* marker) { }

} // namespace toit

#endif
