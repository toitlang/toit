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
#include "program_memory.h"

#include <errno.h>
#include <memoryapi.h>
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
    : level_(level), name_(name) {
    pthread_mutex_init(&mutex_, null);
  }

  ~Mutex() {
    pthread_mutex_destroy(&mutex_);
  }

  void lock() {
    int error = pthread_mutex_lock(&mutex_);
    if (error != 0) FATAL("mutex lock failed with error %d", error);
  }

  void unlock() {
    int error = pthread_mutex_unlock(&mutex_);
    if (error != 0) FATAL("mutex unlock failed with error %d", error);
  }

  bool is_locked() {
    int error = pthread_mutex_trylock(&mutex_);
    if (error == 0) {
      unlock();
      return false;
    }
    if (error != EBUSY) FATAL("mutex trylock failed with error %d", error);
    return true;
  }

  int level() const { return level_; }
  const char* name() const { return name_?name_:""; }
  int level_;
  pthread_mutex_t mutex_;
  const char* name_;
};

class ConditionVariable {
 public:
  explicit ConditionVariable(Mutex* mutex)
      : mutex_(mutex) {
    if (pthread_cond_init(&cond_, NULL) != 0) {
      FATAL("pthread_cond_init() error");
    }
  }

  ~ConditionVariable() {
    pthread_cond_destroy(&cond_);
  }

  void wait() {
    if (pthread_cond_wait(&cond_, &mutex_->mutex_) != 0) {
      FATAL("pthread_cond_timedwait() error");
    }
  }

  bool wait_us(int64 us) {
    if (us <= 0LL) return false;

    // TODO: We really should use monotonic time here.
    struct timespec deadline = { 0, };
    if (!OS::get_real_time(&deadline)) {
      FATAL("cannot get time for deadline");
    }
    OS::timespec_increment(&deadline, us * 1000LL);
    int error = pthread_cond_timedwait(&cond_, &mutex_->mutex_, &deadline);
    if (error == 0) return true;
    if (error == ETIMEDOUT) return false;
    FATAL("pthread_cond_timedwait() error: %d", error);
  }

  void signal() {
    if (!mutex_->is_locked()) {
      FATAL("signal on unlocked mutex");
    }
    int error = pthread_cond_signal(&cond_);
    if (error != 0) {
      FATAL("pthread_cond_signal() error: %d", error);
    }
  }

  void signal_all() {
    if (!mutex_->is_locked()) {
      FATAL("signal_all on unlocked mutex");
    }
    int error = pthread_cond_broadcast(&cond_);
    if (error != 0) {
      FATAL("pthread_cond_broadcast() error: %d", error);
    }
  }

 private:
  Mutex* mutex_;
  pthread_cond_t cond_;
};

void Locker::leave() {
  Thread* thread = Thread::current();
  if (thread->locker_ != this) FATAL("unlocking would break lock order");
  thread->locker_ = previous_;
  // Perform the actual unlock.
  mutex_->unlock();
}

void Locker::enter() {
  Thread* thread = Thread::current();
  int level = mutex_->level();
  Locker* previous_locker = thread->locker_;
  if (previous_locker != null) {
    int previous_level = previous_locker->mutex_->level();
    if (level <= previous_level) {
      FATAL("trying to take lock of level %d (%s) while holding lock of level %d (%s)", level, mutex_->name(), previous_level, previous_locker->mutex_->name());
    }
  }
  // Lock after checking the precondition to avoid deadlocking
  // instead of just failing the precondition check.
  mutex_->lock();
  // Only update variables after we have the lock - that grants right
  // to update the locker.
  previous_ = thread->locker_;
  thread->locker_ = this;
}

static pthread_key_t thread_key;

static pthread_t pthread_from_handle(void* handle) {
  return reinterpret_cast<pthread_t>(handle);
}

Thread::Thread(const char* name)
    : name_(name)
    , handle_(null)
    , locker_(null) {
  USE(name_);
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
  int result = pthread_create(reinterpret_cast<pthread_t*>(&handle_), null, &thread_start, void_cast(this));
  if (result != 0) {
    FATAL("pthread_create failed");
  }
  return true;
}

// Run on current thread.
void Thread::run() {
  ASSERT(handle_ == null);
  thread_start(void_cast(this));
}

void Thread::join() {
  ASSERT(handle_ != null);
  void* return_value;
  pthread_join(pthread_from_handle(handle_), &return_value);
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
  global_mutex_ = allocate_mutex(0, "Global mutex");
  scheduler_mutex_ = allocate_mutex(4, "Scheduler mutex");
  resource_mutex_ = allocate_mutex(99, "Resource mutex");
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
void OS::wait(ConditionVariable* condition) { condition->wait(); }
bool OS::wait_us(ConditionVariable* condition, int64 us) { return condition->wait_us(us); }
void OS::signal(ConditionVariable* condition) { condition->signal(); }
void OS::signal_all(ConditionVariable* condition) { condition->signal_all(); }
void OS::dispose(ConditionVariable* condition) { delete condition; }

void OS::close(int fd) {}

void OS::out_of_memory(const char* reason) {
  fprintf(stderr, "%s; aborting.\n", reason);
  abort();
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

void* OS::grab_virtual_memory(void* address, uword size) {
  size = Utils::round_up(size, 4096);
  void* result = VirtualAlloc(address, size, MEM_RESERVE, PAGE_NOACCESS);
  return result;
}

void OS::ungrab_virtual_memory(void* address, uword size) {
  if (!address) return;
  BOOL ok = VirtualFree(address, 0, MEM_RELEASE);
  if (!ok) FATAL("ungrab_virtual_memory");
}

bool OS::use_virtual_memory(void* addr, uword sz) {
  ASSERT(addr != null);
  if (sz == 0) return true;
  uword address = reinterpret_cast<uword>(addr);
  uword end = address + sz;
  uword rounded = Utils::round_down(address, 4096);
  uword size = Utils::round_up(end - rounded, 4096);
  void* result = VirtualAlloc(reinterpret_cast<void*>(rounded), size, MEM_COMMIT, PAGE_READWRITE);
  if (result != reinterpret_cast<void*>(rounded)) FATAL("use_virtual_memory");
  return true;
}

void OS::unuse_virtual_memory(void* addr, uword sz) {
  uword address = reinterpret_cast<uword>(addr);
  uword end = address + sz;
  uword rounded = Utils::round_up(address, 4096);
  uword size = Utils::round_down(end - rounded, 4096);
  if (size != 0) {
    BOOL ok = VirtualFree(reinterpret_cast<void*>(rounded), size, MEM_DECOMMIT);
    if (!ok) FATAL("unuse_virtual_memory");
  }
}

void OS::free_block(ProgramBlock* block) {
  _aligned_free(block);
}

void OS::set_writable(ProgramBlock* block, bool value) {
  // TODO(anders): Unimplemented.
}

void OS::tear_down() {
  dispose(global_mutex_);
  dispose(scheduler_mutex_);
  dispose(resource_mutex_);
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
