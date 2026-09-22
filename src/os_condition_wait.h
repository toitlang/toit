// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

namespace toit {

// The per-thread resources a timed condition-variable wait needs: a wake
// signal, a signal that the timer callback has completed, and the timer.
//
// The template is independent of the platform headers so the allocation
// rollback can be tested without a scheduler. After a failed initialize()
// the instance owns nothing; after a successful one it owns all three.
// dispose() must only run after any pending timer callback has finished.
template <typename Platform>
struct ConditionWaitResources {
  typename Platform::Signal wake = nullptr;
  typename Platform::Signal callback_complete = nullptr;
  typename Platform::Timer timer = nullptr;

  bool initialize_wake() {
    if (wake == nullptr) wake = Platform::create_signal();
    return wake != nullptr;
  }

  bool initialize(typename Platform::Callback callback) {
    if (timer != nullptr) return true;
    if (initialize_wake()) {
      callback_complete = Platform::create_signal();
      if (callback_complete != nullptr) timer = Platform::create_timer(callback, this);
    }
    if (timer != nullptr) return true;
    dispose();
    return false;
  }

  void dispose() {
    if (timer != nullptr) Platform::delete_timer(timer);
    if (callback_complete != nullptr) Platform::delete_signal(callback_complete);
    if (wake != nullptr) Platform::delete_signal(wake);
    timer = nullptr;
    callback_complete = nullptr;
    wake = nullptr;
  }
};

}  // namespace toit
