// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

#include <stdint.h>

namespace toit {

// Shared reset flags. Keep these values in sync with lib/system/power.toit.
struct ResetReason {
  enum : uint32_t {
    UNKNOWN = 0,
    PIN = 1 << 0,
    SOFTWARE = 1 << 1,
    BROWNOUT = 1 << 2,
    POWER_ON = 1 << 3,
    WATCHDOG = 1 << 4,
    DEBUG = 1 << 5,
    SECURITY = 1 << 6,
    LOW_POWER_WAKE = 1 << 7,
    CPU_LOCKUP = 1 << 8,
    PARITY = 1 << 9,
    PLL = 1 << 10,
    CLOCK = 1 << 11,
    HARDWARE = 1 << 12,
    USER = 1 << 13,
    TEMPERATURE = 1 << 14,
    BOOTLOADER = 1 << 15,
    FLASH = 1 << 16,
  };
};

}  // namespace toit
