// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .native as native

/**
An exclusive ESP32 VHCI controller transport.

Requires firmware configured with the controller-only Bluetooth host option.
  Supports the original ESP32 and ESP32-S3 in BLE-only mode. The native ingress
  queue stays in internal RAM for lock-free counters, including when the managed
  heap uses PSRAM. The SDK keeps ESP-IDF's PSRAM atomic workaround enabled for
  other native code.

Explicit close reports HARDWARE_ERROR if controller disable or deinitialization
  fails, after releasing the native resource. Exact controller errors are logged.
  A caller must not treat an idempotent subsequent close as proof of recovery.
*/
class Esp32Transport extends native.NativeTransport:
  constructor:
    super 0 --packet-limit=1029
