// Copyright (C) 2026 Toit contributors.
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

#ifdef TOIT_NO_THREADS

#include "os.h"
#include "utils.h"

namespace toit {

// On platforms without threads, all code runs on the thread that called
// OS::set_up. Blocking on a condition variable would block forever, since
// there is nobody else who could signal it. Components that wait on
// condition variables on threaded platforms are driven by an event loop
// instead (see Scheduler::run_ready and EventSource::poll).
class ConditionVariable {
 public:
  explicit ConditionVariable(Mutex* mutex) : mutex_(mutex) {}

  void wait() {
    FATAL("cannot wait for a condition without threads");
  }

  bool wait_us(int64 us) {
    FATAL("cannot wait for a condition without threads");
  }

  void signal() {
    if (!mutex_->is_locked()) {
      FATAL("signal on unlocked mutex");
    }
  }

  void signal_all() {
    if (!mutex_->is_locked()) {
      FATAL("signal_all on unlocked mutex");
    }
  }

 private:
  Mutex* mutex_;
};

static Thread* main_thread = null;

Thread::Thread(const char* name)
    : name_(name)
    , handle_(null)
    , locker_(null) {
  USE(name_);
}

bool Thread::spawn(int stack_size, int core) {
  // Report the failure to the caller, who can then fail gracefully.
  return false;
}

void Thread::run() {
  FATAL("cannot run a thread without threads");
}

void Thread::cancel() {
  ASSERT(handle_ == null);
}

void Thread::join() {
  ASSERT(handle_ == null);
}

void Thread::ensure_system_thread() {
  if (main_thread != null) return;
  main_thread = _new SystemThread();
  if (main_thread == null) FATAL("unable to allocate SystemThread");
}

Thread* Thread::current() {
  if (main_thread == null) FATAL("thread must be present");
  return main_thread;
}

void OS::set_up() {
  Thread::ensure_system_thread();
  set_up_mutexes();
}

void OS::tear_down() {
  tear_down_mutexes();
}

// Condition variable forwarders.
ConditionVariable* OS::allocate_condition_variable(Mutex* mutex) { return _new ConditionVariable(mutex); }
void OS::wait(ConditionVariable* condition) { condition->wait(); }
bool OS::wait_us(ConditionVariable* condition, int64 us) { return condition->wait_us(us); }
void OS::signal(ConditionVariable* condition) { condition->signal(); }
void OS::signal_all(ConditionVariable* condition) { condition->signal_all(); }
void OS::dispose(ConditionVariable* condition) { delete condition; }

} // namespace toit

#endif  // TOIT_NO_THREADS
