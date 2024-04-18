// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import cron.cron show *

main:
  test-simple-1
  test-simple-2
  test-simple-3
  test-wrap-around-hours
  test-wrap-around-days-1
  test-wrap-around-days-2
  test-wrap-around-days-3
  test-wrap-around-days-4
  test-wrap-around-days-5
  test-wrap-around-days-6
  test-wrap-around-days-7
  test-wrap-around-days-8
  test-wrap-around-months-1
  test-wrap-around-months-2
  test-wrap-around-months-3
  test-wrap-around-years-1
  test-wrap-around-years-2
  test-wrap-around-minute-hour-day-month-year
  test-leap-year
  test-no-match-1
  test-no-match-2

validate-next-run start/Time expected-next/Time? schedule-from-text/CronSchedule schedule-from-console/CronSchedule:
  expect-equals expected-next (schedule-from-console.next start)
  expect-equals expected-next (schedule-from-text.next start)

test-simple-1:
  validate-next-run
     Time.utc 2012 7 9 14 45 0
     Time.utc 2012 7 9 15 0 0
     CronSchedule.parse "0 0/15 * * * *"
     CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-simple-2:
  validate-next-run
    Time.utc 2012 7 9 14 59 0
    Time.utc 2012 7 9 15 0 0
    CronSchedule.parse "0 0/15 * * * *"
    CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-simple-3:
  validate-next-run
    Time.utc 2012 7 9 14 59 59
    Time.utc 2012 7 9 15 0 0
    CronSchedule.parse "0 0/15 * * * *"
    CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-wrap-around-hours:
  validate-next-run
    Time.utc 2012 7 9 15 45 0
    Time.utc 2012 7 9 16 20 0
    CronSchedule.parse "0 20-35/15 * * * *"
    CronSchedule 1 34360786944 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-wrap-around-days-1:
  validate-next-run
    Time.utc 2012 7 9 23 46 0
    Time.utc 2012 7 10 0 0 0
    CronSchedule.parse "0 */15 * * * *"
    CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-wrap-around-days-2:
  validate-next-run
    Time.utc 2012 7 9 23 45 0
    Time.utc 2012 7 10 0 20 0
    CronSchedule.parse "0 20-35/15 * * * *"
    CronSchedule 1 34360786944 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-wrap-around-days-3:
  validate-next-run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 0 20 15
    CronSchedule.parse "15/35 20-35/15 * * * *"
    CronSchedule 1125899906875392 34360786944 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-wrap-around-days-4:
  validate-next-run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 1 20 15
    CronSchedule.parse "15/35 20-35/15 1/2 * * *"
    CronSchedule 1125899906875392 34360786944 11184810 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-wrap-around-days-5:
  validate-next-run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 10 20 15
    CronSchedule.parse "15/35 20-35/15 10-12 * * *"
    CronSchedule 1125899906875392 34360786944 7168 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-wrap-around-days-6:
  validate-next-run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 11 1 20 15
    CronSchedule.parse "15/35 20-35/15 1/2 */2 * *"
    CronSchedule 1125899906875392 34360786944 11184810 2863311530 -9223372036854767618 -9223372036854775681

test-wrap-around-days-7:
  validate-next-run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 0 20 15
    CronSchedule.parse "15/35 20-35/15 * 9-20 * *"
    CronSchedule 1125899906875392 34360786944 -9223372036837998593 2096640 -9223372036854767618 -9223372036854775681

test-wrap-around-days-8:
  validate-next-run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 0 20 15
    CronSchedule.parse "15/35 20-35/15 * 9-20 7 *"  // Jul
    CronSchedule 1125899906875392 34360786944 -9223372036837998593 2096640 128 -9223372036854775681

test-wrap-around-months-1:
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2012 8 9 0 0 0
    CronSchedule.parse "0 0 0 9 4-10 *"  // Apr-Oct
    CronSchedule 1 1 1 512 2032 -9223372036854775681

test-wrap-around-months-2:
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2012 8 1 0 0 0
    CronSchedule.parse  "0 0 0 */5 4,8,10 1"  // Apr,Aug,Oct Mon
    CronSchedule 1 1 1 2216757314 1296 2

test-wrap-around-months-3:
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2012 10 1 0 0 0
    CronSchedule.parse "0 0 0 */5 10 1"  // Oct Mon
    CronSchedule 1 1 1 2216757314 1024 2

test-wrap-around-years-1:
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2013 2 4 0 0 0
    CronSchedule.parse "0 0 0 * 2 1"  // Feb Mon
    CronSchedule 1 1 1 -9223372032559808514 4 2

test-wrap-around-years-2: // "0 0 0 * Feb Mon/2"
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2013 2 1 0 0 0
    CronSchedule.parse "0 0 0 * 2 1/2"  // Feb Mon
    CronSchedule 1 1 1 -9223372032559808514 4 42

test-wrap-around-minute-hour-day-month-year:
  validate-next-run
    Time.utc 2012 12 31 23 59 45
    Time.utc 2013 1 1 0 0 0
    CronSchedule.parse "0 * * * * *"
    CronSchedule 1 -8070450532247928833 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test-leap-year: // "0 0 0 29 Feb ?"
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2016 2 29 0 0 0
    CronSchedule.parse "0 0 0 29 2 *"  // Feb
    CronSchedule 1 1 1 536870912 4 -9223372036854775681

test-no-match-1:
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    null
    CronSchedule.parse "0 0 0 30 2 *"  // Feb
    CronSchedule 1 1 1 1073741824 4 -9223372036854775681

test-no-match-2:
  validate-next-run
    Time.utc 2012 7 9 23 35 0
    null
    CronSchedule.parse "0 0 0 31 4 *"  // Apr
    CronSchedule 1 1 1 2147483648 16 -9223372036854775681
