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

    // Use ceiling divisions to avoid rounding the ticks down and thus
    // not waiting long enough.
    uint32 ms = 1 + static_cast<uint32>((us - 1) / 1000LL);
    uint32 ticks = (ms + portTICK_PERIOD_MS - 1) / portTICK_PERIOD_MS;
    return wait_ticks(ticks);
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
    bool success = xSemaphoreTake(waiter.wake, ticks) == pdTRUE;
    mutex_->lock();

    TAILQ_REMOVE(&waiter_list_, &waiter, link);
    return success;
  }

  void signal() {
    if (!mutex_->is_locked()) FATAL("signal on unlocked mutex");
    ConditionVariableWaiter* waiter = TAILQ_FIRST(&waiter_list_);
    if (waiter) xSemaphoreGive(waiter->wake);
  }

  void signal_all() {
    if (!mutex_->is_locked()) FATAL("signal_all on unlocked mutex");
    ConditionVariableWaiter* waiter;
    TAILQ_FOREACH(waiter, &waiter_list_, link) {
      xSemaphoreGive(waiter->wake);
    }
  }

 private:
  Mutex* mutex_;
  TAILQ_HEAD(, ConditionVariableWaiter) waiter_list_;
};

}  // namespace toit

#endif  // TOIT_FREERTOS
