// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

#include <stdint.h>

namespace toit {

struct I2sEventState {
  static constexpr uint32_t READ = 1 << 0;
  static constexpr uint32_t WRITE = 1 << 1;
  static constexpr uint32_t ERROR = 1 << 2;

  static uint32_t merge(uint32_t state, uint32_t pending) {
    // ISR callbacks coalesce their bits before enqueueing a wake-up token.
    // Combined notifications are as valid as individual notifications.
    return state | (pending & (READ | WRITE | ERROR));
  }
};

}  // namespace toit
