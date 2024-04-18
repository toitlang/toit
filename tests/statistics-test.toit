// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import statistics show *
import expect show *

main:
  test-serialization

test-serialization:
  empty-stats := OnlineStatistics

  expect-equals
    empty-stats
    OnlineStatistics.from-byte-array empty-stats.to-byte-array

  stats := OnlineStatistics
  10.repeat:
    stats.update it

  expect-equals
    stats
    OnlineStatistics.from-byte-array stats.to-byte-array
