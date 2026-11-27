// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .rig-test-esp32 as rig

/** Pulses the RP2350 RUN line low through the ESP32 open-drain output. */
main:
  rig.pulse-run
