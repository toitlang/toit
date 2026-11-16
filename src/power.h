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
#ifdef TOIT_ESP32
// Called after VM resources are gone and the default RTC pulls are cleared.
void power_prepare_esp32_sleep();
#endif
}  // namespace toit
