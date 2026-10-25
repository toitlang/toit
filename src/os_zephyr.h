// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "top.h"
#ifdef TOIT_ZEPHYR
#include "os.h"
#include <zephyr/kernel.h>
namespace toit {
class ConditionVariable {
 public:
  explicit ConditionVariable(Mutex* mutex) : mutex_(mutex) { k_condvar_init(&condition_); }
  void wait() {
    if (k_condvar_wait(&condition_, &mutex_->mutex_, K_FOREVER) != 0) FATAL("condition wait failed");
  }
  bool wait_us(int64 us) {
    if (us <= 0) return false;
    int result = k_condvar_wait(&condition_, &mutex_->mutex_, K_USEC(us));
    if (result != 0 && result != -EAGAIN) FATAL("condition timed wait failed: %d", result);
    return result == 0;
  }
  void signal() { k_condvar_signal(&condition_); }
  void signal_all() { k_condvar_broadcast(&condition_); }
 private:
  Mutex* mutex_;
  struct k_condvar condition_;
};
}  // namespace toit
#endif
