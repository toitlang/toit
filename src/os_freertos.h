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

#pragma once

#include "top.h"

#ifdef TOIT_FREERTOS

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <sys/queue.h>

#include "os.h"

namespace toit {

struct ConditionVariableWaiter {
  StaticSemaphore_t storage;
  SemaphoreHandle_t wake;
  bool signaled;
  TAILQ_ENTRY(ConditionVariableWaiter) link;
};

class ConditionVariable {
 public:
  explicit ConditionVariable(Mutex* mutex)
    : mutex_(mutex) {
    TAILQ_INIT(&waiter_list_);
  }

  ~ConditionVariable() {}

  void wait() {
    wait_ticks(portMAX_DELAY);
  }

  bool wait_us(int64 us) {
    if (us <= 0LL) return false;

    if (us > OS::MAX_WAIT_US) us = OS::MAX_WAIT_US;
    // Round up before narrowing. portMAX_DELAY is reserved for wait().
    static_assert(portTICK_PERIOD_MS > 0, "expected a tick period of at least one millisecond");
    int64 ticks = 1 + (us - 1) / (1000LL * portTICK_PERIOD_MS);
    if (ticks >= portMAX_DELAY) ticks = portMAX_DELAY - 1;
    return wait_ticks(static_cast<uint32>(ticks));
  }

  bool wait_ticks(uint32 ticks) {
    if (!mutex_->is_locked()) FATAL("wait on unlocked mutex");

    // A semaphore scoped to this wait cannot leave a notification for a later
    // wait on this task. Static allocation also keeps waiting infallible.
    ConditionVariableWaiter waiter{};
    waiter.wake = xSemaphoreCreateBinaryStatic(&waiter.storage);
    ASSERT(waiter.wake != null);
    TAILQ_INSERT_TAIL(&waiter_list_, &waiter, link);

    mutex_->unlock();
    bool woke = xSemaphoreTake(waiter.wake, ticks) == pdTRUE;
    mutex_->lock();

    if (waiter.signaled) {
      // If the semaphore wait timed out, a signal claimed this waiter while it
      // was reacquiring the mutex. Consume that signal before the stack-backed
      // semaphore goes out of scope.
      if (!woke && xSemaphoreTake(waiter.wake, 0) != pdTRUE) {
        FATAL("condition-variable signal without semaphore wakeup");
      }
    } else {
      // No signal claimed this waiter, so it is still on the list.
      TAILQ_REMOVE(&waiter_list_, &waiter, link);
      if (woke) FATAL("condition-variable wakeup without signal");
    }
    return waiter.signaled;
  }

  void signal() {
    if (!mutex_->is_locked()) FATAL("signal on unlocked mutex");
    ConditionVariableWaiter* waiter = TAILQ_FIRST(&waiter_list_);
    if (waiter) {
      TAILQ_REMOVE(&waiter_list_, waiter, link);
      waiter->signaled = true;
      if (xSemaphoreGive(waiter->wake) != pdTRUE) {
        FATAL("unable to signal condition variable");
      }
    }
  }

  void signal_all() {
    if (!mutex_->is_locked()) FATAL("signal_all on unlocked mutex");
    while (ConditionVariableWaiter* waiter = TAILQ_FIRST(&waiter_list_)) {
      TAILQ_REMOVE(&waiter_list_, waiter, link);
      waiter->signaled = true;
      if (xSemaphoreGive(waiter->wake) != pdTRUE) {
        FATAL("unable to signal condition variable");
      }
    }
  }

 private:
  Mutex* mutex_;
  TAILQ_HEAD(, ConditionVariableWaiter) waiter_list_;
};

}  // namespace toit

#endif  // TOIT_FREERTOS
