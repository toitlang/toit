// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Whether the wall clock time is set.
// After power booting an embedded device, this is often not set.
is_epoch_set -> bool:
  return Time.now.s_since_epoch >= 1_577_750_400 // (Time --year=2020).s_since_epoch

// Convert seconds to UTC time info as:
//  Array_[seconds/int, minutes/int, hours/int, day/int, month/int, year/int, weekday/int, is_dst/bool].
time_info_ seconds/int is_utc/bool:
  #primitive.core.time_info

/**
Stores the given $rules in the `TZ` environment variable and
  calls `tzset`, thus activating it.
Valid TZ values can be easily obtained by looking at the last line of the
  zoneinfo files on Linux machines:
```
tail -n1 /usr/share/zoneinfo/Europe/Copenhagen
```
*/
set_tz_ rules/string:
  #primitive.core.set_tz

// Returns real time clock as Array_[seconds/int, ns/int].
get_real_time_clock:
  #primitive.core.get_real_time_clock

/// Returns null if the values can't be represented.
seconds_since_epoch_local_ year/int month/int day/int hour/int min/int sec/int is_dst/bool? -> int?:
  #primitive.core.seconds_since_epoch_local

// The following code is ported from GO to Toit (Thanks GO team).
// https://golang.org/src/time/time.go (BSD-style license)

// DAYS_BEFORE[m] counts the number of days in a non-leap year
// before month m begins. There is an entry for m=12, counting
// the number of days before January of next year (365).
DAYS_BEFORE ::= [
  0,
  31,
  31 + 28,
  31 + 28 + 31,
  31 + 28 + 31 + 30,
  31 + 28 + 31 + 30 + 31,
  31 + 28 + 31 + 30 + 31 + 30,
  31 + 28 + 31 + 30 + 31 + 30 + 31,
  31 + 28 + 31 + 30 + 31 + 30 + 31 + 31,
  31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30,
  31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31,
  31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30,
  31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30 + 31,
]

MARCH ::= 2

// The unsigned zero year for internal calculations.
// Must be 1 mod 400, and times before it will not compute correctly,
// but otherwise can be changed at will.
ABSOLUTE_ZERO_YEAR ::= 1601

// The year of the zero Time.
// Assumed by the unixToInternal computation below.
INTERNAL_YEAR ::= 1

// Offsets to convert between internal and absolute or Unix times.
ABSOLUTE_TO_INTERNAL ::= ((ABSOLUTE_ZERO_YEAR - INTERNAL_YEAR) * 365.2425 * SECONDS_PER_DAY).to_int
INTERNAL_TO_ABSOLUTE ::= -ABSOLUTE_TO_INTERNAL
EPOCH_TO_INTERNAL    ::= (1969*365 + 1969/4 - 1969/100 + 1969/400) * SECONDS_PER_DAY
INTERNAL_TO_EPOCH    ::= -EPOCH_TO_INTERNAL
WALL_TO_INTERNAL     ::= (1884*365 + 1884/4 - 1884/100 + 1884/400) * SECONDS_PER_DAY
INTERNAL_TO_WALL     ::= -WALL_TO_INTERNAL
ABSOLUTE_TO_EPOCH    ::= ABSOLUTE_TO_INTERNAL + INTERNAL_TO_EPOCH

SECONDS_PER_MINUTE ::= 60
SECONDS_PER_HOUR   ::= 60 * SECONDS_PER_MINUTE
SECONDS_PER_DAY    ::= 24 * SECONDS_PER_HOUR
SECONDS_PER_WEEK   ::=  7 * SECONDS_PER_DAY
DAYS_PER_400_YEARS ::= 365*400 + 97
DAYS_PER_100_YEARS ::= 365*100 + 24
DAYS_PER_4_YEARS   ::= 365*4 + 1

// Is year a leap year?
is_leap year/int -> bool:
  return year % 4 == 0 and
      year % 100 != 0 or year % 400 == 0

// Normalize high and low with respect to base.
normalize high/int low/int base/int [block] -> int:
  if low < 0:
    n ::= (-low - 1)/base + 1
    high -= n
    low += n * base
  if low >= base:
    n ::= low / base
    high += n
    low -= n * base
  block.call low  // Call block with the normalized low.
  return high  // Return the normalized high

// Unix epoch is the number of seconds that have elapsed since January 1, 1970
seconds_since_epoch_utc_ year/int month/int day/int hour/int min/int sec/int -> int:
  year = normalize year month 12: month = it
  min  = normalize min  sec   60: sec = it
  hour = normalize hour min   60: min = it
  day  = normalize day hour   24: hour = it

  y := year - ABSOLUTE_ZERO_YEAR

  // Add in days from 400-year cycles.
  n := y / 400
  y -= 400 * n
  d := DAYS_PER_400_YEARS * n

  // Add in 100-year cycles.
  n = y / 100
  y -= 100 * n
  d += DAYS_PER_100_YEARS * n

  // Add in 4-year cycles.
  n = y / 4
  y -= 4 * n
  d += DAYS_PER_4_YEARS * n

  // Add in non-leap years.
  n = y
  d += 365 * n

  // Add in days before this month.
  d += DAYS_BEFORE[month]
  if is_leap year and month >= MARCH: d++ // February 29

  // Add in days before today.
  d += day - 1

  // Add in time elapsed today.
  abs := d * SECONDS_PER_DAY
  abs += hour*SECONDS_PER_HOUR + min*SECONDS_PER_MINUTE + sec

  // Convert to Epoch
  return abs + ABSOLUTE_TO_EPOCH
