// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The consolidated GPIO test verifies PAD42 directly through the classic
// ESP32 helper, without using a powered sensor as an indirect output probe.
import .gpio-map-ec618 as suite

main:
  suite.main
