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

#include "primitive.h"
#include "process.h"
#include "watchdog.h"

namespace toit {

MODULE_IMPLEMENTATION(watchdog, MODULE_WATCHDOG)

PRIMITIVE(start) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_RP2350)
  ARGS(int, timeout_ms);
  return platform_watchdog_start(process, timeout_ms);
#else
  FAIL(UNIMPLEMENTED);
#endif
}

PRIMITIVE(feed) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_RP2350)
  return platform_watchdog_feed(process);
#else
  FAIL(UNIMPLEMENTED);
#endif
}

PRIMITIVE(stop) {
#if defined(TOIT_ESP32) || defined(TOIT_EC618) || defined(TOIT_RP2350)
  return platform_watchdog_stop(process);
#else
  FAIL(UNIMPLEMENTED);
#endif
}

}  // namespace toit
