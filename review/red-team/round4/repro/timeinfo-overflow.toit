// Copyright (C) 2026 Toit contributors.
// Round-4 line-F finding: time_info (untrusted-allowed C++ primitive,
// docs/sandbox-policy.md read-only clock access) decomposes an int64 timestamp
// in utc_fields (src/primitive_core.cc:1243-1244) with
//   days = floor_div(timestamp, SECONDS_PER_DAY)
//   seconds_of_day = timestamp - days * SECONDS_PER_DAY
// For a timestamp near INT64_MIN, `days * SECONDS_PER_DAY` and the following
// subtraction overflow a signed int64 -> undefined behaviour (UBSan trips).
// The subsequent Smi::is_valid32(year) check still throws OUT_OF_RANGE, so no
// wrong value escapes on a two's-complement release build, but it is UB
// reachable by an untrusted container through a DIRECT time_info primitive call
// (an untrusted program can declare #primitive.core.time_info and pass any
// int64, as below). The public Time.utc / Time.local wrapper caps the seconds
// via its microsecond conversion and does not reach the overflow boundary.
//
// Reproduce (UBSan build):
//   build/asan/sdk/lib/toit/bin/toit.run --untrusted <this compiled --untrusted>
//   -> ../../src/primitive_core.cc:1244: runtime error: signed integer overflow
time-info_ ts/int is-utc/bool: #primitive.core.time_info

main:
  // is_utc = true goes straight to utc_fields; is_utc = false reaches it via
  // local_fields's fallback. Both overflow for INT64_MIN.
  print (catch: time-info_ (-9223372036854775808) true)
  print (catch: time-info_ (-9223372036854775808) false)
  print (catch: time-info_ 9223372036854775807 true)
  print "timeinfo-overflow-done"
