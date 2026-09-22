// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import encoding.hex
import .vhci-security-client as fixture

// Runs on S3 Board2 against lab ESP32 Board2 running vhci-numeric-pairing.
main:
  fixture.run (hex.decode "98cdac60e0ae").reverse
