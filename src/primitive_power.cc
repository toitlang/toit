// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#include "objects_inline.h"
#include "power.h"
#include "primitive.h"
#include "process.h"

namespace toit {
MODULE_IMPLEMENTATION(power, MODULE_POWER)

PRIMITIVE(check_reset) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_ZEPHYR)
  return process->null_object();
#else
  FAIL(UNIMPLEMENTED);
#endif
}

PRIMITIVE(prepare_sleep) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_ZEPHYR)
  ARGS(int64, duration_ms);
#ifdef TOIT_ZEPHYR
  if (duration_ms != INT64_MIN && (duration_ms < 1 || duration_ms > 24 * 60 * 60 * 1000)) {
    FAIL(INVALID_ARGUMENT);
  }
#endif
  // Validate before the HALT intrinsic stops every container.
  return Primitive::integer(duration_ms, process);
#else
  FAIL(UNIMPLEMENTED);
#endif
}

PRIMITIVE(supports_timed_sleep) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_ZEPHYR)
  return BOOL(true);
#else
  return BOOL(false);
#endif
}

PRIMITIVE(reset_reason) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_ZEPHYR)
  return platform_reset_reason(process);
#else
  FAIL(UNIMPLEMENTED);
#endif
}

PRIMITIVE(configure_wakeup_pin) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_ZEPHYR)
  ARGS(int, pin, int, flags);
  if (flags != 0 && (!(flags & WAKE_ENABLED) || (flags & ~0x3f) != 0 ||
      (flags & WAKE_TRIGGER_MASK) == WAKE_TRIGGER_MASK ||
      (flags & (WAKE_PULL_UP | WAKE_PULL_DOWN)) == (WAKE_PULL_UP | WAKE_PULL_DOWN))) {
    FAIL(INVALID_ARGUMENT);
  }
  return platform_configure_wakeup_pin(process, pin, flags);
#else
  FAIL(UNIMPLEMENTED);
#endif
}
}  // namespace toit
