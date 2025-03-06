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

#ifdef TOIT_POSIX

#include "os.h"
#include "process.h"
#include "program.h"
#include "utils.h"
#include "uuid.h"
#include "vm.h"

#include <errno.h>
#include <pthread.h>
#include <sys/time.h>
#include <unistd.h>
#include <sys/mman.h>

namespace toit {

char* OS::get_executable_path_from_arg(const char* source_arg) {
  return realpath(source_arg, null);
}

int64 OS::get_system_time() {
  int64 us;
  if (!monotonic_gettime(&us)) {
    FATAL("failed getting system time");
  }
  return us;
}

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
      FATAL("pthread_cond_wait() error");
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

void Thread::cancel() {
  ASSERT(handle_ != null);
  pthread_cancel(pthread_from_handle(handle_));
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
  set_up_mutexes();
}

void OS::tear_down() {
  tear_down_mutexes();
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

void OS::close(int fd) {
  ::close(fd);
}

void OS::out_of_memory(const char* reason) {
  fprintf(stderr, "%s; aborting.\n", reason);
  abort();
}

char* OS::getenv(const char* variable) {
  // Getenv/setenv are not guaranteed to be reentrant.
  Locker scope(global_mutex_);
  char* result = ::getenv(variable);
  if (result == null) return null;
  return strdup(result);
}

bool OS::setenv(const char* variable, const char* value) {
  Locker scope(global_mutex_);
  return ::setenv(variable, value, 1) == 0;
}

bool OS::unsetenv(const char* variable) {
  Locker scope(global_mutex_);
  return ::unsetenv(variable) == 0;
}

bool OS::set_real_time(struct timespec* time) {
  FATAL("cannot set the time");
}

void OS::heap_summary_report(int max_pages, const char* marker, Process* process) {
  const uint8* uuid = process->program()->id();
  fprintf(stderr, "Out of memory process %d: %08x-%04x-%04x-%04x-%04x%08x.\n",
      process->id(),
      static_cast<int>(Utils::read_unaligned_uint32_be(uuid)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 4)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 6)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 8)),
      static_cast<int>(Utils::read_unaligned_uint16_be(uuid + 10)),
      static_cast<int>(Utils::read_unaligned_uint32_be(uuid + 12)));
}

ProtectableAlignedMemory::~ProtectableAlignedMemory() {
  int status = mprotect(address(), byte_size(), PROT_READ | PROT_WRITE);
  if (status != 0) perror("~ProtectableAlignedMemory. mark_read_write");
}

void ProtectableAlignedMemory::mark_read_only() {
  int status = mprotect(address(), byte_size(), PROT_READ);
  if (status != 0) perror("mark_read_only");
}

size_t ProtectableAlignedMemory::compute_alignment(size_t alignment) {
  size_t system_page_size = getpagesize();
  return Utils::max(alignment, system_page_size);
}

const char* OS::get_architecture() {
#if defined(__aarch64__)
  return "arm64";
#elif defined(__arm__)
  return "arm";
#elif defined(__amd64__)
  return "x86_64";
#elif defined(__i386__)
  return "x86";
#else
  #error "Unknown architecture"
#endif
}

} // namespace toit

#endif
