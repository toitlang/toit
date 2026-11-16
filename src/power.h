// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "top.h"

namespace toit {
class Object;
class Process;
Object* platform_reset_reason(Process* process);
// Device-wide wake configuration. Zero disables a pin.
enum WakePinConfig {
  WAKE_HIGH = 1,
  WAKE_PULL_UP = 2,
  WAKE_PULL_DOWN = 4,
  WAKE_ENABLED = 8,
  WAKE_TRIGGER_LEVEL = 1 << 4,
  WAKE_TRIGGER_EDGE = 2 << 4,
  WAKE_TRIGGER_MASK = 3 << 4,
};
Object* platform_configure_wakeup_pin(Process* process, int pin, int flags);

// Snapshot wire format: three bytes per source (kind, pin/input, effective flags).
// Keep in sync with lib/system/power-wakeup_.toit.
enum WakeupSourceKind {
  WAKE_SOURCE_PIN = 0,
  WAKE_SOURCE_INPUT = 1,
  WAKE_SOURCE_TOUCH = 2,
};
enum WakeupSourceFlags {
  WAKE_BOTH_EDGES = 1 << 6,
  WAKE_ALL_LOW = 1 << 7,
};
struct WakeupSources {
  // At most 64 GPIOs plus one touch-controller source on supported platforms.
  uint8 data[65 * 3];
  int size = 0;
  void add(int kind, int id, int flags) {
    ASSERT(size + 3 <= static_cast<int>(sizeof(data)));
    data[size++] = kind;
    data[size++] = id;
    data[size++] = flags;
  }
};
// Takes a coherent snapshot under the same lock used by configuration.
void platform_wakeup_sources(WakeupSources* sources);
#ifdef TOIT_ESP32
// Called after VM resources are gone and the default RTC pulls are cleared.
void power_prepare_esp32_sleep();
#endif
}  // namespace toit
