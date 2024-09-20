// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Whether the wall clock time is set.
// After power booting an embedded device, this is often not set.
is-epoch-set -> bool:
  return Time.now.s-since-epoch >= 1_577_750_400 // (Time --year=2020).s-since-epoch

/**
Converts seconds to UTC time info.

Returns an array with the following elements:
  [seconds/int, minutes/int, hours/int, day/int, month/int, year/int, weekday/int, is-dst/bool].
*/
time-info_ seconds/int is-utc/bool:
  #primitive.core.time-info

/**
Deprecated. Use $set-timezone instead.
*/
set-tz_ rules/string:
  #primitive.core.set-tz

// Returns real time clock as Array_[seconds/int, ns/int].
get-real-time-clock:
  #primitive.core.get-real-time-clock

/// Returns null if the values can't be represented.
seconds-since-epoch-local_ year/int month/int day/int hour/int min/int sec/int is-dst/bool? -> int?:
  #primitive.core.seconds-since-epoch-local

// The following code is ported from GO to Toit (Thanks GO team).
// https://golang.org/src/time/time.go (BSD-style license)

/**
Counts the number of days in a non-leap year before month m begins.

There is an entry for m=12, counting the number of days before January of
  next year (365).
*/
DAYS-BEFORE ::= [
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
ABSOLUTE-ZERO-YEAR ::= 1601

// The year of the zero Time.
// Assumed by the unixToInternal computation below.
INTERNAL-YEAR ::= 1

// Offsets to convert between internal and absolute or Unix times.
ABSOLUTE-TO-INTERNAL ::= ((ABSOLUTE-ZERO-YEAR - INTERNAL-YEAR) * 365.2425 * SECONDS-PER-DAY).to-int
INTERNAL-TO-ABSOLUTE ::= -ABSOLUTE-TO-INTERNAL
EPOCH-TO-INTERNAL    ::= (1969*365 + 1969/4 - 1969/100 + 1969/400) * SECONDS-PER-DAY
INTERNAL-TO-EPOCH    ::= -EPOCH-TO-INTERNAL
WALL-TO-INTERNAL     ::= (1884*365 + 1884/4 - 1884/100 + 1884/400) * SECONDS-PER-DAY
INTERNAL-TO-WALL     ::= -WALL-TO-INTERNAL
ABSOLUTE-TO-EPOCH    ::= ABSOLUTE-TO-INTERNAL + INTERNAL-TO-EPOCH

SECONDS-PER-MINUTE ::= 60
SECONDS-PER-HOUR   ::= 60 * SECONDS-PER-MINUTE
SECONDS-PER-DAY    ::= 24 * SECONDS-PER-HOUR
SECONDS-PER-WEEK   ::=  7 * SECONDS-PER-DAY
DAYS-PER-400-YEARS ::= 365*400 + 97
DAYS-PER-100-YEARS ::= 365*100 + 24
DAYS-PER-4-YEARS   ::= 365*4 + 1

// Is year a leap year?
is-leap year/int -> bool:
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
seconds-since-epoch-utc_ year/int month/int day/int hour/int min/int sec/int -> int:
  year = normalize year month 12: month = it
  min  = normalize min  sec   60: sec = it
  hour = normalize hour min   60: min = it
  day  = normalize day hour   24: hour = it

  y := year - ABSOLUTE-ZERO-YEAR

  // Add in days from 400-year cycles.
  n := y / 400
  y -= 400 * n
  d := DAYS-PER-400-YEARS * n

  // Add in 100-year cycles.
  n = y / 100
  y -= 100 * n
  d += DAYS-PER-100-YEARS * n

  // Add in 4-year cycles.
  n = y / 4
  y -= 4 * n
  d += DAYS-PER-4-YEARS * n

  // Add in non-leap years.
  n = y
  d += 365 * n

  // Add in days before this month.
  d += DAYS-BEFORE[month]
  if is-leap year and month >= MARCH: d++ // February 29

  // Add in days before today.
  d += day - 1

  // Add in time elapsed today.
  abs := d * SECONDS-PER-DAY
  abs += hour*SECONDS-PER-HOUR + min*SECONDS-PER-MINUTE + sec

  // Convert to Epoch
  return abs + ABSOLUTE-TO-EPOCH
