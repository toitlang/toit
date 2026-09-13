// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Measures long transfers against the S3 target. Probes have a fixed 100 kHz
// rate and therefore cannot serve as a proxy for per-device transfer speed.
import .bus-controller-ec618 as suite

main:
  suite.main ["speed"]
