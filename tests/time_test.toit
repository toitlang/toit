// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import core.time_impl show set_tz_

h1  ::= Duration --h=1
m1  ::= Duration --m=1
s1  ::= Duration --s=1
n1  ::= Duration --ns=1
m59 ::= Duration --m=59

EXAMPLES ::= [
  "2019-12-18T06:22:04Z",
  "2019-12-18T08:05:24Z",
  "2025-01-12T00:00:00Z",
  "2020-10-01T15:02:04",
]

test_time_string str/string:
  time ::= Time.from_string str
  if str.ends_with "Z":
    expect_equals str time.stringify
    expect_equals str time.utc.stringify
  else:
    expect_equals str time.local.stringify

main:
  time := Time.now
  expect time == time       --message="Time == #0"
  expect time - m1 < time   --message="Time >"
  expect time > time - m1   --message="Time <"
  expect time + m1 >= time  --message="Time >="
  expect time <= time + m1  --message="Time <="
  expect h1 - m1 == m59     --message="Duration =="
  expect time + m59 == time + (h1 - m1) --message="Time == #1"

  // Check nanoseconds normalization.
  duration := (Time.epoch --s=0 --ns=600_000_000).to (Time.epoch --s=1 --ns=500_000_000)
  expect duration == (Duration 900_000_000) --message="Time - underflow"
  duration = (Duration 1_500_000_000) - (Duration 1_600_000_000)
  expect duration == (Duration -100_000_000) --message="Duration - underflow"
  duration = (Duration 1_000_000_000) / 2
  expect duration == (Duration 500_000_000) --message="Duration division"

  // Check Time operations.
  t0 / Time ::= Time.now
  t1 / Time ::= t0.plus --s=1
  expect_equals
    Duration --s=1
    t0.to t1
  expect_equals
    Duration.ZERO
    (t0.to t1) + (t1.to t0)

  // Check passed negative ns are normalized.
  expect_equals
    Time.epoch --s=0 --ns=500_000_000
    Time.epoch --s=1 --ns=-500_000_000
  expect_equals
    Time.epoch --s=0 --ns=2_500_000_000
    Time.epoch --s=5 --ns=-2_500_000_000

  // Check setting time info and checking the result.
  info := time.utc
  expect_equals 13 (info.with --s=13).s
  expect_equals 12 (info.with --m=12).m
  expect_equals 11 (info.with --h=11).h
  expect_equals 10 (info.with --day=10).day
  // The month must be one of the 31-days months, as the day could be 31. If
  // we picked a 30-day month (or February), then the month would roll over and
  // the test fails. See #3685.
  expect_equals 3  (info.with --month=3).month
  expect_equals 1908 (info.with --year=1908).year
  expect_equals 13 (info.with --s=13).time.utc.s
  expect_equals 12 (info.with --m=12).time.utc.m
  expect_equals 11 (info.with --h=11).time.utc.h
  expect_equals 10 (info.with --day=10).time.utc.day
  expect_equals 3  (info.with --month=3).time.utc.month
  expect_equals 1908 (info.with --year=1908).time.utc.year

  info = (Time.utc 2020 10 01 15 24 37).utc
  expect_equals 2020 info.year
  expect_equals 10 info.month
  expect_equals 01 info.day
  expect_equals 15 info.h
  expect_equals 24 info.m
  expect_equals 37 info.s
  info2 := info.plus
      --years=1
      --months=-2
      --days=3
      --h=-4
      --m=5
      --s=-6
  expect_equals 2021 info2.year
  expect_equals 08 info2.month
  expect_equals 04 info2.day
  expect_equals 11 info2.h
  expect_equals 29 info2.m
  expect_equals 31 info2.s
  expect info2.is_utc

  info = (Time.local 2020 10 01 15 24 37).local
  expect_equals 2020 info.year
  expect_equals 10 info.month
  expect_equals 01 info.day
  expect_equals 15 info.h
  expect_equals 24 info.m
  expect_equals 37 info.s
  info2 = info.plus
      --years=1
      --months=-2
      --days=3
      --h=-4
      --m=5
      --s=-6
  expect_equals 2021 info2.year
  expect_equals 08 info2.month
  expect_equals 04 info2.day
  expect_equals 11 info2.h
  expect_equals 29 info2.m
  expect_equals 31 info2.s
  expect_not info2.is_utc

  expect_equals 13 (info.with --s=13).time.local.s
  expect_equals 12 (info.with --m=12).time.local.m
  expect_equals 11 (info.with --h=11).time.local.h
  expect_equals 10 (info.with --day=10).time.local.day
  expect_equals 9  (info.with --month=9).time.local.month
  expect_equals 1908 (info.with --year=1908).time.local.year

  EXAMPLES.do: test_time_string it

  d / Duration := Duration --h=1 --m=2 --s=3 --ms=4 --us=5 --ns=6
  expect_equals 3723004005006 d.in_ns

  time1 := Time.now

  d = Duration.of:
    sleep --ms=2
  expect d.in_ms >= 2

  d = Duration.since time1
  expect d.in_ms >= 2
  expect_equals 0 d.in_m  // Even if the test runs slowly, it should never reach 1 min.

  time_in_1_hour := time1.utc.with --h=(time1.utc.h + 1)
  d = Duration.until time_in_1_hour.time
  expect d.in_m >= 59

  d = time1.to time_in_1_hour.time
  expect_equals 60 d.in_m
  expect_equals Duration.NANOSECONDS_PER_HOUR d.in_ns

  d = time1.to Time.now
  expect 0 <= d.in_m <= 1

  d2 := time1.to_now
  expect 0 <= d2.in_m <= 1
  expect d2 >= d

  time2 := Time.epoch --s=1603591140
  time3 := time2 - (Duration --h=1)
  expect_equals (1603591140 - 60 * 60) time3.s_since_epoch

  time2 = Time.local 2020 09 08 18 03 11 --ns=123456789
  local := time2.local
  expect_equals 2020 local.year
  expect_equals 09 local.month
  expect_equals 08 local.day
  expect_equals 18 local.h
  expect_equals 03 local.m
  expect_equals 11 local.s
  expect_equals 123456789 local.ns

  set_tz_ "CET-1CEST,M3.5.0,M10.5.0/3"
  time3 = Time.local 2020 09 08 18 03 11 --ns=123456789
  expect_equals 1599580991 time3.s_since_epoch
  expect_equals 123456789 time3.ns_part

  local = time3.local
  expect_equals 2020 local.year
  expect_equals 09 local.month
  expect_equals 08 local.day
  expect_equals 18 local.h
  expect_equals 03 local.m
  expect_equals 11 local.s
  expect_equals 123456789 local.ns
  expect local.is_dst

  set_tz_ "EST5EDT,M3.2.0,M11.1.0"
  time4 := Time.local 2020 09 08 18 03 11 --ns=123456789
  expect_equals 1599602591 time4.s_since_epoch
  expect_equals 123456789 time4.ns_part

  local = time4.local
  expect_equals 2020 local.year
  expect_equals 09 local.month
  expect_equals 08 local.day
  expect_equals 18 local.h
  expect_equals 03 local.m
  expect_equals 11 local.s
  expect_equals 123456789 local.ns
  expect local.is_dst

  time4_100_days_later := time4 + (Duration --h=24 * 100)
  expect_not time4_100_days_later.local.is_dst

  set_tz_ "CET-1CEST,M3.5.0,M10.5.0/3"
  earlier := Time.local 2020 10 25 2 59
  later / Time := ?
  if earlier.local.is_dst:
    later = earlier + (Duration --h=1)
  else:
    later = earlier
    earlier = later - (Duration --h=1)
  expect_equals 1603587540 earlier.s_since_epoch
  expect_equals 1603591140 later.s_since_epoch
  expect earlier.local.is_dst
  expect_not later.local.is_dst

  // Both times show 2:59 on the wall.
  expect_equals 2 earlier.local.h
  expect_equals 59 earlier.local.m
  expect_equals 2 later.local.h
  expect_equals 59 later.local.m

  // We can force to get one or the other using the `--dst` flag.
  earlier2 := Time.local 2020 10 25 2 59 --dst
  later2 := Time.local 2020 10 25 2 59 --no-dst

  expect_equals earlier earlier2
  expect_equals later later2

  sep9 := Time.utc 2020 09 09 12
  expect_equals TimeInfo.WEDNESDAY sep9.utc.weekday
  expect_equals TimeInfo.THURSDAY  (sep9 + (Duration --h=24)).utc.weekday
  expect_equals TimeInfo.FRIDAY    (sep9 + (Duration --h=2 * 24)).utc.weekday
  expect_equals TimeInfo.SATURDAY  (sep9 + (Duration --h=3 * 24)).utc.weekday
  expect_equals TimeInfo.SUNDAY    (sep9 + (Duration --h=4 * 24)).utc.weekday
  expect_equals TimeInfo.MONDAY    (sep9 + (Duration --h=5 * 24)).utc.weekday
  expect_equals TimeInfo.TUESDAY   (sep9 + (Duration --h=6 * 24)).utc.weekday

  expect_equals 1 TimeInfo.MONDAY
  expect_equals 7 TimeInfo.SUNDAY

  // Duration operators
  d1 := Duration --h=1
  d2 = Duration --h=2 --m=1
  expect_equals (Duration --h=3 --m=1)  d1 + d2
  expect_equals (Duration --h=2) d1 +   d1
  expect_equals (Duration --h=1 --m=1)  d2 - d1
  expect_equals (Duration --h=-1)       -d1
  expect_equals (Duration --h=4 --m=2)  d2 * 2
  expect_equals (Duration --h=1 --s=30) d2 / 2

  with_dst := Time.local 2020 10 25 2 59 --dst
  without_dst := Time.local 2020 10 25 2 59 --no-dst
  expect with_dst < without_dst

  info = with_dst.local
  expect_equals 2020 info.year
  expect_equals 10 info.month
  expect_equals 25 info.day
  expect_equals 02 info.h
  expect_equals 59 info.m
  expect_equals 0 info.s
  expect info.is_dst

  info2 = without_dst.local
  expect_equals 2020 info2.year
  expect_equals 10 info2.month
  expect_equals 25 info2.day
  expect_equals 02 info2.h
  expect_equals 59 info2.m
  expect_equals 0 info2.s
  expect_not info2.is_dst

  after_dst_info := info.plus --h=1
  after_dst_info2 := info.plus --h=1
  expect_equals after_dst_info.time after_dst_info2.time
  expect_equals 2020 after_dst_info.year
  expect_equals 2020 after_dst_info2.year
  expect_equals 10 after_dst_info.month
  expect_equals 10 after_dst_info2.month
  expect_equals 25 after_dst_info.day
  expect_equals 25 after_dst_info2.day
  expect_equals 03 after_dst_info.h
  expect_equals 03 after_dst_info2.h
  expect_equals 59 after_dst_info.m
  expect_equals 59 after_dst_info2.m
  expect_equals 0 after_dst_info.s
  expect_equals 0 after_dst_info2.s
  expect_not after_dst_info.is_dst
  expect_not after_dst_info2.is_dst

  expect_equals "0s" (Duration --s=0).stringify
  expect_equals "1s" (Duration --s=1).stringify
  expect_equals "1h1m1s" (Duration --m=1 --h=1 --s=1).stringify
  expect_equals "1h0m0.001s" (Duration --h=1 --ms=1).stringify
  expect_equals "1h0m0.000001s" (Duration --h=1 --us=1).stringify
  expect_equals "1h0m0.000000001s" (Duration --h=1 --ns=1).stringify
  expect_equals "1h0m0.999999999s" (Duration --h=1 --ns=999999999).stringify
  expect_equals "2540400h10m10s" (Duration --h=2540400 --m=10 --s=10).stringify
  expect_equals "2540400h10m10.999999999s" (Duration --h=2540400 --m=10 --s=10 --ns=999999999).stringify
  expect_equals "1ns" (Duration --ns=1).stringify
  expect_equals "1us" (Duration --us=1).stringify
  expect_equals "1ms" (Duration --ms=1).stringify
  expect_equals "1.234us" (Duration --ns=1234).stringify
  expect_equals "20m34.56789s" (Duration --us=1234567890).stringify
  expect_equals "-1ns" (Duration --ns=-1).stringify
  expect_equals "-2540400h10m10.999999999s" (Duration --h=-2540400 --m=-10 --s=-10 --ns=-999999999).stringify
  expect_equals "2562047h47m16.854775807s" (Duration --ns=0x7FFF_FFFF_FFFF_FFFF).stringify
  expect_equals "-2562047h47m16.854775808s" (Duration --ns=0x8000_0000_0000_0000).stringify
  expect_equals "-2562047h47m16.854775807s" (Duration --ns=0x8000_0000_0000_0001).stringify

  zero_duration := Duration
  expect_equals zero_duration zero_duration.abs
  expect_equals (Duration --h=1 --s=3) (Duration --h=-1 --s=-3).abs
  expect_throw "OUT_OF_RANGE": (Duration --ns=int.MIN).abs

  expect_equals 0 (zero_duration.compare_to zero_duration)
  expect_equals
      -1
      (Duration --s=1).compare_to (Duration --s=2)
  expect_equals
      1
      (Duration --s=2).compare_to (Duration --s=1)
  expect_equals
      -1
      (Duration --s=-10).compare_to (Duration --s=-9)
  expect_equals
      1
      (Duration --s=-9).compare_to (Duration --s=-10)
