// Copyright (C) 2021 Toitware ApS. All rights reserved.

import statistics show *
import expect show *

main:
  test_serialization

test_serialization:
  empty_stats := OnlineStatistics

  expect_equals
    empty_stats
    OnlineStatistics.from_byte_array empty_stats.to_byte_array

  stats := OnlineStatistics
  10.repeat:
    stats.update it

  expect_equals
    stats
    OnlineStatistics.from_byte_array stats.to_byte_array
