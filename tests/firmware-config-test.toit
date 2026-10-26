// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.firmware

main:
  // No firmware service is installed, so the config is empty.
  expect-null firmware.config["hostname"]
  expect-equals #[] firmware.config.ubjson
