// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .rig-test-esp32 as rig

/** Enters RP2350 BOOTSEL by asserting BOOT before pulsing RUN. */
main:
  rig.enter-bootsel
