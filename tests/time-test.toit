// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

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
  "2023-10-01T15:02:04.1Z",
  "2023-10-01T15:02:04.2Z",
  "2023-10-01T15:02:04.3Z",
  "2023-10-01T15:02:04.4Z",
  "2023-10-01T15:02:04.5Z",
  "2023-10-01T15:02:04.6Z",
  "2023-10-01T15:02:04.7Z",
  "2023-10-01T15:02:04.8Z",
  "2023-10-01T15:02:04.9Z",
  "2023-10-01T15:02:04.11Z",
  "2023-10-01T15:02:04.111Z",
  "2023-10-01T15:02:04.1111Z",
  "2023-10-01T15:02:04.11111Z",
  "2023-10-01T15:02:04.111111Z",
  "2023-10-01T15:02:04.1111111Z",
  "2023-10-01T15:02:04.11111111Z",
  "2023-10-01T15:02:04.111111111Z",
  "2023-10-01T15:02:59.000338385Z",  // Fails if we use floor instead of round.
  ["2019-12-18T06:22Z", "2019-12-18T06:22:00Z"],
  ["2019-12-18T08:05", "2019-12-18T08:05:00"],
  ["2025-01-12T00:00Z", "2025-01-12T00:00:00Z"],
]

TZ-TIMES ::= [
  ["2020-10-01T15:12:04+02:10", "2020-10-01T13:02:04Z"],
  ["2020-10-01T15:02:04-02:10", "2020-10-01T17:12:04Z"],
  ["2020-10-01T15:02:04+00:00", "2020-10-01T15:02:04Z"],
  ["2020-10-01T15:02:04Z", "2020-10-01T15:02:04Z"],
]

test-time-string test:
  str/string := ?
  expected/string := ?
  if test is List:
    str = test[0]
    expected = test[1]
  else:
    str = test
    expected = str
  time ::= Time.parse str
  if str.ends-with "Z":
    expect-equals expected time.stringify
    expect-equals expected time.utc.stringify
  else:
    expect-equals expected time.local.stringify

main:
  time-test
  nanosecond-normalization-test
  negative-ns-test
  time-operations-test
  set-time-info-test
  simple-constructor-test
  examples-test
  duration-test
  set-timezone-test
  duration-operator-test
  duration-stringify-test
  duration-compare-test
  rounded-test

time-test:
  time := Time.now
  expect time == time       --message="Time == #0"
  expect time - m1 < time   --message="Time >"
  expect time > time - m1   --message="Time <"
  expect time + m1 >= time  --message="Time >="
  expect time <= time + m1  --message="Time <="
  expect h1 - m1 == m59     --message="Duration =="
  expect time + m59 == time + (h1 - m1) --message="Time == #1"

nanosecond-normalization-test:
  // Check nanoseconds normalization.
  duration := (Time.epoch --s=0 --ns=600_000_000).to (Time.epoch --s=1 --ns=500_000_000)
  expect duration == (Duration 900_000_000) --message="Time - underflow"
  duration = (Duration 1_500_000_000) - (Duration 1_600_000_000)
  expect duration == (Duration -100_000_000) --message="Duration - underflow"
  duration = (Duration 1_000_000_000) / 2
  expect duration == (Duration 500_000_000) --message="Duration division"

time-operations-test:
  // Check Time operations.
  t0 / Time ::= Time.now
  t1 / Time ::= t0.plus --s=1
  expect-equals
    Duration --s=1
    t0.to t1
  expect-equals
    Duration.ZERO
    (t0.to t1) + (t1.to t0)

negative-ns-test:
  // Check passed negative ns are normalized.
  expect-equals
    Time.epoch --s=0 --ns=500_000_000
    Time.epoch --s=1 --ns=-500_000_000
  expect-equals
    Time.epoch --s=0 --ns=2_500_000_000
    Time.epoch --s=5 --ns=-2_500_000_000

set-time-info-test:
  // Check setting time info and checking the result.
  time := Time.now
  info := time.utc
  expect-equals 13 (info.with --s=13).s
  expect-equals 12 (info.with --m=12).m
  expect-equals 11 (info.with --h=11).h
  expect-equals 10 (info.with --day=10).day
  // The month must be one of the 31-days months, as the day could be 31. If
  // we picked a 30-day month (or February), then the month would roll over and
  // the test fails. See #3685.
  expect-equals 3  (info.with --month=3).month
  expect-equals 1908 (info.with --year=1908).year
  expect-equals 13 (info.with --s=13).time.utc.s
  expect-equals 12 (info.with --m=12).time.utc.m
  expect-equals 11 (info.with --h=11).time.utc.h
  expect-equals 10 (info.with --day=10).time.utc.day
  expect-equals 3  (info.with --month=3).time.utc.month
  expect-equals 1908 (info.with --year=1908).time.utc.year

simple-constructor-test:
  info := (Time.utc 2020 10 01 15 24 37).utc
  expect-equals 2020 info.year
  expect-equals 10 info.month
  expect-equals 01 info.day
  expect-equals 15 info.h
  expect-equals 24 info.m
  expect-equals 37 info.s
  info2 := info.plus
      --years=1
      --months=-2
      --days=3
      --h=-4
      --m=5
      --s=-6
  expect-equals 2021 info2.year
  expect-equals 08 info2.month
  expect-equals 04 info2.day
  expect-equals 11 info2.h
  expect-equals 29 info2.m
  expect-equals 31 info2.s
  expect info2.is-utc

  info = (Time.local 2020 10 01 15 24 37).local
  expect-equals 2020 info.year
  expect-equals 10 info.month
  expect-equals 01 info.day
  expect-equals 15 info.h
  expect-equals 24 info.m
  expect-equals 37 info.s
  info2 = info.plus
      --years=1
      --months=-2
      --days=3
      --h=-4
      --m=5
      --s=-6
  expect-equals 2021 info2.year
  expect-equals 08 info2.month
  expect-equals 04 info2.day
  expect-equals 11 info2.h
  expect-equals 29 info2.m
  expect-equals 31 info2.s
  expect-not info2.is-utc

  expect-equals 13 (info.with --s=13).time.local.s
  expect-equals 12 (info.with --m=12).time.local.m
  expect-equals 11 (info.with --h=11).time.local.h
  expect-equals 10 (info.with --day=10).time.local.day
  expect-equals 9  (info.with --month=9).time.local.month
  expect-equals 1908 (info.with --year=1908).time.local.year

examples-test:
  EXAMPLES.do: test-time-string it


duration-test:
  d / Duration := Duration --h=1 --m=2 --s=3 --ms=4 --us=5 --ns=6
  expect-equals 3723004005006 d.in-ns

  time1 := Time.now

  d = Duration.of:
    sleep --ms=2
  expect d.in-ms >= 2

  d = Duration.since time1
  expect d.in-ms >= 2
  expect-equals 0 d.in-m  // Even if the test runs slowly, it should never reach 1 min.

  time-in-1-hour := time1.utc.with --h=(time1.utc.h + 1)
  d = Duration.until time-in-1-hour.time
  expect d.in-m >= 59

  d = time1.to time-in-1-hour.time
  expect-equals 60 d.in-m
  expect-equals Duration.NANOSECONDS-PER-HOUR d.in-ns

  d = time1.to Time.now
  expect 0 <= d.in-m <= 1

  d2 := time1.to-now
  expect 0 <= d2.in-m <= 1
  expect d2 >= d

  time2 := Time.epoch --s=1603591140
  time3 := time2 - (Duration --h=1)
  expect-equals (1603591140 - 60 * 60) time3.s-since-epoch

  time2 = Time.local 2020 09 08 18 03 11 --ns=123456789
  local := time2.local
  expect-equals 2020 local.year
  expect-equals 09 local.month
  expect-equals 08 local.day
  expect-equals 18 local.h
  expect-equals 03 local.m
  expect-equals 11 local.s
  expect-equals 123456789 local.ns

set-timezone-test:
  set-timezone "CET-1CEST,M3.5.0,M10.5.0/3"
  time := Time.local 2020 09 08 18 03 11 --ns=123456789
  expect-equals 1599580991 time.s-since-epoch
  expect-equals 123456789 time.ns-part

  local := time.local
  expect-equals 2020 local.year
  expect-equals 09 local.month
  expect-equals 08 local.day
  expect-equals 18 local.h
  expect-equals 03 local.m
  expect-equals 11 local.s
  expect-equals 123456789 local.ns
  expect local.is-dst

  set-timezone "EST5EDT,M3.2.0,M11.1.0"
  time2 := Time.local 2020 09 08 18 03 11 --ns=123456789
  expect-equals 1599602591 time2.s-since-epoch
  expect-equals 123456789 time2.ns-part

  local = time2.local
  expect-equals 2020 local.year
  expect-equals 09 local.month
  expect-equals 08 local.day
  expect-equals 18 local.h
  expect-equals 03 local.m
  expect-equals 11 local.s
  expect-equals 123456789 local.ns
  expect local.is-dst

  time4-100-days-later := time2 + (Duration --h=24 * 100)
  expect-not time4-100-days-later.local.is-dst

  set-timezone "CET-1CEST,M3.5.0,M10.5.0/3"
  earlier := Time.local 2020 10 25 2 59
  later / Time := ?
  if earlier.local.is-dst:
    later = earlier + (Duration --h=1)
  else:
    later = earlier
    earlier = later - (Duration --h=1)
  expect-equals 1603587540 earlier.s-since-epoch
  expect-equals 1603591140 later.s-since-epoch
  expect earlier.local.is-dst
  expect-not later.local.is-dst

  // Both times show 2:59 on the wall.
  expect-equals 2 earlier.local.h
  expect-equals 59 earlier.local.m
  expect-equals 2 later.local.h
  expect-equals 59 later.local.m

  // We can force to get one or the other using the `--dst` flag.
  earlier2 := Time.local 2020 10 25 2 59 --dst
  later2 := Time.local 2020 10 25 2 59 --no-dst

  expect-equals earlier earlier2
  expect-equals later later2

  sep9 := Time.utc 2020 09 09 12
  expect-equals TimeInfo.WEDNESDAY sep9.utc.weekday
  expect-equals TimeInfo.THURSDAY  (sep9 + (Duration --h=24)).utc.weekday
  expect-equals TimeInfo.FRIDAY    (sep9 + (Duration --h=2 * 24)).utc.weekday
  expect-equals TimeInfo.SATURDAY  (sep9 + (Duration --h=3 * 24)).utc.weekday
  expect-equals TimeInfo.SUNDAY    (sep9 + (Duration --h=4 * 24)).utc.weekday
  expect-equals TimeInfo.MONDAY    (sep9 + (Duration --h=5 * 24)).utc.weekday
  expect-equals TimeInfo.TUESDAY   (sep9 + (Duration --h=6 * 24)).utc.weekday

  expect-equals 1 TimeInfo.MONDAY
  expect-equals 7 TimeInfo.SUNDAY

duration-operator-test:
  d1 := Duration --h=1
  d2 := Duration --h=2 --m=1
  expect-equals (Duration --h=3 --m=1)  d1 + d2
  expect-equals (Duration --h=2) d1 +   d1
  expect-equals (Duration --h=1 --m=1)  d2 - d1
  expect-equals (Duration --h=-1)       -d1
  expect-equals (Duration --h=4 --m=2)  d2 * 2
  expect-equals (Duration --h=4 --m=2)  d2 * 2.0
  expect-equals (Duration --h=1 --s=30) d2 * 0.5
  expect-equals (Duration --h=1 --s=30) d2 / 2
  expect-equals (Duration --h=4 --m=2)  d2 / 0.5

  with-dst := Time.local 2020 10 25 2 59 --dst
  without-dst := Time.local 2020 10 25 2 59 --no-dst
  expect with-dst < without-dst

  info := with-dst.local
  expect-equals 2020 info.year
  expect-equals 10 info.month
  expect-equals 25 info.day
  expect-equals 02 info.h
  expect-equals 59 info.m
  expect-equals 0 info.s
  expect info.is-dst

  info2 := without-dst.local
  expect-equals 2020 info2.year
  expect-equals 10 info2.month
  expect-equals 25 info2.day
  expect-equals 02 info2.h
  expect-equals 59 info2.m
  expect-equals 0 info2.s
  expect-not info2.is-dst

  after-dst-info := info.plus --h=1
  after-dst-info2 := info.plus --h=1
  expect-equals after-dst-info.time after-dst-info2.time
  expect-equals 2020 after-dst-info.year
  expect-equals 2020 after-dst-info2.year
  expect-equals 10 after-dst-info.month
  expect-equals 10 after-dst-info2.month
  expect-equals 25 after-dst-info.day
  expect-equals 25 after-dst-info2.day
  expect-equals 03 after-dst-info.h
  expect-equals 03 after-dst-info2.h
  expect-equals 59 after-dst-info.m
  expect-equals 59 after-dst-info2.m
  expect-equals 0 after-dst-info.s
  expect-equals 0 after-dst-info2.s
  expect-not after-dst-info.is-dst
  expect-not after-dst-info2.is-dst

duration-stringify-test:
  expect-equals "0s" (Duration --s=0).stringify
  expect-equals "1s" (Duration --s=1).stringify
  expect-equals "1h1m1s" (Duration --m=1 --h=1 --s=1).stringify
  expect-equals "1h0m0.001s" (Duration --h=1 --ms=1).stringify
  expect-equals "1h0m0.000001s" (Duration --h=1 --us=1).stringify
  expect-equals "1h0m0.000000001s" (Duration --h=1 --ns=1).stringify
  expect-equals "1h0m0.999999999s" (Duration --h=1 --ns=999999999).stringify
  expect-equals "2540400h10m10s" (Duration --h=2540400 --m=10 --s=10).stringify
  expect-equals "2540400h10m10.999999999s" (Duration --h=2540400 --m=10 --s=10 --ns=999999999).stringify
  expect-equals "1ns" (Duration --ns=1).stringify
  expect-equals "1us" (Duration --us=1).stringify
  expect-equals "1ms" (Duration --ms=1).stringify
  expect-equals "1.234us" (Duration --ns=1234).stringify
  expect-equals "20m34.56789s" (Duration --us=1234567890).stringify
  expect-equals "-1ns" (Duration --ns=-1).stringify
  expect-equals "-2540400h10m10.999999999s" (Duration --h=-2540400 --m=-10 --s=-10 --ns=-999999999).stringify
  expect-equals "2562047h47m16.854775807s" (Duration --ns=0x7FFF_FFFF_FFFF_FFFF).stringify
  expect-equals "-2562047h47m16.854775808s" (Duration --ns=0x8000_0000_0000_0000).stringify
  expect-equals "-2562047h47m16.854775807s" (Duration --ns=0x8000_0000_0000_0001).stringify

duration-compare-test:
  zero-duration := Duration
  expect-equals zero-duration zero-duration.abs
  expect-equals (Duration --h=1 --s=3) (Duration --h=-1 --s=-3).abs
  expect-throw "OUT_OF_RANGE": (Duration --ns=int.MIN).abs

  expect-equals 0 (zero-duration.compare-to zero-duration)
  expect-equals
      -1
      (Duration --s=1).compare-to (Duration --s=2)
  expect-equals
      1
      (Duration --s=2).compare-to (Duration --s=1)
  expect-equals
      -1
      (Duration --s=-10).compare-to (Duration --s=-9)
  expect-equals
      1
      (Duration --s=-9).compare-to (Duration --s=-10)

  TZ-TIMES.do:
    left := it[0]
    right := it[1]
    expect-equals
      Time.parse left
      Time.parse right

  now := Time.now
  parsed := Time.parse "invalid" --on-error=: now
  expect-equals now parsed

rounded-test:
  t := Time.parse "2019-06-19T00:00:00Z"
  i := t.utc
  expect-equals "2019-06-19" i.to-iso-date-string
  t2 := Time.parse "2019-06-18T23:59:59Z"
  i2 := t2.utc
  expect-equals "2019-06-18" i2.to-iso-date-string
  t3 := Time.parse "2023-01-26T15:59:33.000001Z"
  i3 := t3.utc
  expect-equals "2023-01-26T15:59:33Z" (i3.with --ns=0).to-iso8601-string
