// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Uses the S3's clock-stretched target response and checks cancellation/reuse.
import .bus-controller-ec618 as suite

main:
  suite.main ["stretch"]
