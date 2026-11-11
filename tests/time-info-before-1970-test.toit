// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The time-info primitive must handle times before 1970 (negative
// timestamps) on all platforms, in UTC and in local time. The C library of
// Windows rejects them (gmtime_s and localtime_s fail with EINVAL).

time-info timestamp/int is-utc/bool -> List:
  #primitive.core.time-info

SECONDS-PER-DAY ::= 24 * 60 * 60

/**
Checks the result of time-info.

The $expected list has the entries [year, month (1-12), day, h, m, s,
  weekday (0-6, Sunday is 0), yearday (0-365)].
*/
check timestamp/int --is-utc/bool expected/List --is-dst/bool=false:
  info := time-info timestamp is-utc
  expect-equals 9 info.size
  actual := [info[5], info[4] + 1, info[3], info[2], info[1], info[0], info[6], info[7]]
  expect-equals expected actual
  expect-equals is-dst info[8]

check-utc timestamp/int expected/List:
  check timestamp --is-utc expected

check-local timestamp/int expected/List --is-dst/bool=false:
  check timestamp --no-is-utc expected --is-dst=is-dst

main:
  test-utc
  test-utc-calendar
  test-utc-against-time-utc
  test-local-default-zone
  test-local-fixed-offset
  test-local-daylight-saving

test-utc:
  check-utc 0 [1970, 1, 1, 0, 0, 0, 4, 0]
  check-utc -1 [1969, 12, 31, 23, 59, 59, 3, 364]
  check-utc -14_182_980 [1969, 7, 20, 20, 17, 0, 0, 200]  // Moon landing.
  check-utc -18_871_200 [1969, 5, 27, 14, 0, 0, 2, 146]
  check-utc -30_283_200 [1969, 1, 15, 12, 0, 0, 3, 14]
  check-utc -2_208_988_800 [1900, 1, 1, 0, 0, 0, 1, 0]
  check-utc -11_670_953_104 [1600, 2, 29, 12, 34, 56, 2, 59]
  check-utc -11_670_912_000 [1600, 3, 1, 0, 0, 0, 3, 60]
  check-utc -12_219_292_800 [1582, 10, 15, 0, 0, 0, 5, 287]
  check-utc -62_135_596_800 [1, 1, 1, 0, 0, 0, 1, 0]
  check-utc -62_162_035_200 [0, 3, 1, 0, 0, 0, 3, 60]
  check-utc -62_167_219_200 [0, 1, 1, 0, 0, 0, 6, 0]
  check-utc -62_167_219_201 [-1, 12, 31, 23, 59, 59, 5, 364]
  check-utc -86_400_000_000 [-768, 2, 4, 0, 0, 0, 3, 34]

is-leap year/int -> bool:
  return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)

DAYS-IN-MONTH ::= [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

/**
Walks day by day through a full 400-year cycle of negative timestamps and
  checks that the calendar advances correctly.
*/
test-utc-calendar:
  start := -11_670_912_000 - 60 * SECONDS-PER-DAY  // 1600-01-01.
  check-utc start [1600, 1, 1, 0, 0, 0, 6, 0]
  year := 1600
  month := 1
  day := 1
  weekday := 6
  yearday := 0
  (146_097 + 1).repeat:
    timestamp := start + it * SECONDS-PER-DAY
    // Vary the time of day.
    seconds := (it * 7919) % SECONDS-PER-DAY
    expected := [year, month, day, seconds / 3600, (seconds / 60) % 60, seconds % 60, weekday, yearday]
    info := time-info (timestamp + seconds) true
    actual := [info[5], info[4] + 1, info[3], info[2], info[1], info[0], info[6], info[7]]
    if expected != actual: expect-equals expected actual  // Only build the message on failure.
    days-in-month := DAYS-IN-MONTH[month - 1]
    if month == 2 and is-leap year: days-in-month++
    weekday = (weekday + 1) % 7
    yearday++
    day++
    if day > days-in-month:
      day = 1
      month++
      if month > 12:
        month = 1
        year++
        yearday = 0
  expect-equals 2000 year
  expect-equals 1 month
  expect-equals 2 day

/**
Compares with the computation in the core library, which handles years from
  1601 on.
*/
test-utc-against-time-utc:
  for year := 1601; year <= 1975; year += 3:
    month := 1 + year % 12
    day := 1 + year % 28
    h := year % 24
    m := year % 60
    s := (year * 7) % 60
    time := Time.utc year month day h m s
    utc := time.utc
    expect-equals year utc.year
    expect-equals month utc.month
    expect-equals day utc.day
    expect-equals h utc.h
    expect-equals m utc.m
    expect-equals s utc.s
    // Stringifying a time uses time-info.
    expect-equals "$(year)-$(%02d month)-$(%02d day)T$(%02d h):$(%02d m):$(%02d s)Z" time.stringify

/**
The default zone of the machine is unknown. Check that the local fields are
  consistent with the UTC fields for some offset. (The times are after 1601,
  as $Time.utc only handles years from 1601 on.)
*/
test-local-default-zone:
  [-1, -14_182_980, -30_283_200, -2_208_988_800, -5_000_000_000].do: | timestamp |
    local := time-info timestamp false
    local-seconds := (Time.utc local[5] (local[4] + 1) local[3] local[2] local[1] local[0]).s-since-epoch
    offset := local-seconds - timestamp
    expect offset.abs <= 26 * 3600
    utc := time-info (timestamp + offset) true
    expect-equals utc[..8] local[..8]

test-local-fixed-offset:
  // The zone names are not names of zoneinfo files, so that the C libraries
  //   use the given offsets. The Windows C library only accepts zone names with
  //   three letters.
  set-timezone "ABC5"  // UTC-5.
  check-local 3600 [1969, 12, 31, 20, 0, 0, 3, 364]
  check-local 0 [1969, 12, 31, 19, 0, 0, 3, 364]
  check-local -1 [1969, 12, 31, 18, 59, 59, 3, 364]
  check-local -14_182_980 [1969, 7, 20, 15, 17, 0, 0, 200]
  check-local -2_208_988_800 [1899, 12, 31, 19, 0, 0, 0, 364]
  check-local -62_135_596_800 [0, 12, 31, 19, 0, 0, 0, 365]
  check-local -86_400_000_000 [-768, 2, 3, 19, 0, 0, 2, 33]

  set-timezone "XYZ-9"  // UTC+9.
  check-local -1 [1970, 1, 1, 8, 59, 59, 4, 0]
  check-local -14_182_980 [1969, 7, 21, 5, 17, 0, 1, 201]
  check-local -2_208_988_800 [1900, 1, 1, 9, 0, 0, 1, 0]

  // Time.local uses time-info.
  moon := Time.parse "1969-07-20T20:17:00Z"
  expect-equals 1969 moon.local.year
  expect-equals 21 moon.local.day
  expect-equals 5 moon.local.h

test-local-daylight-saving:
  set-timezone "ABC5XYZ,M3.2.0,M11.1.0"  // UTC-5, UTC-4 in summer.
  // After 1970 all C libraries apply the rules.
  check-local 300_000_000 [1979, 7, 5, 1, 20, 0, 4, 185] --is-dst
  check-local 285_253_200 [1979, 1, 15, 8, 0, 0, 1, 14]
  // No C library has daylight saving in January.
  check-local -30_283_200 [1969, 1, 15, 7, 0, 0, 3, 14]
  // Whether the rules apply before 1970 depends on the C library (glibc
  //   doesn't apply them). The fields must match the reported state.
  info := time-info -14_182_980 false
  if info[8]:
    check-local -14_182_980 [1969, 7, 20, 16, 17, 0, 0, 200] --is-dst
  else:
    check-local -14_182_980 [1969, 7, 20, 15, 17, 0, 0, 200]
