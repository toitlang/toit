// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

import cron.cron show *

main:
  test_simple_1
  test_simple_2
  test_simple_3
  test_wrap_around_hours
  test_wrap_around_days_1
  test_wrap_around_days_2
  test_wrap_around_days_3
  test_wrap_around_days_4
  test_wrap_around_days_5
  test_wrap_around_days_6
  test_wrap_around_days_7
  test_wrap_around_days_8
  test_wrap_around_months_1
  test_wrap_around_months_2
  test_wrap_around_months_3
  test_wrap_around_years_1
  test_wrap_around_years_2
  test_wrap_around_minute_hour_day_month_year
  test_leap_year
  test_no_match_1
  test_no_match_2

validate_next_run start/Time expected_next/Time? schedule_from_text/CronSchedule schedule_from_console/CronSchedule:
  expect_equals expected_next (schedule_from_console.next start)
  expect_equals expected_next (schedule_from_text.next start)

test_simple_1:
  validate_next_run
     Time.utc 2012 7 9 14 45 0
     Time.utc 2012 7 9 15 0 0
     CronSchedule.parse "0 0/15 * * * *"
     CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_simple_2:
  validate_next_run
    Time.utc 2012 7 9 14 59 0
    Time.utc 2012 7 9 15 0 0
    CronSchedule.parse "0 0/15 * * * *"
    CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_simple_3:
  validate_next_run
    Time.utc 2012 7 9 14 59 59
    Time.utc 2012 7 9 15 0 0
    CronSchedule.parse "0 0/15 * * * *"
    CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_wrap_around_hours:
  validate_next_run
    Time.utc 2012 7 9 15 45 0
    Time.utc 2012 7 9 16 20 0
    CronSchedule.parse "0 20-35/15 * * * *"
    CronSchedule 1 34360786944 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_wrap_around_days_1:
  validate_next_run
    Time.utc 2012 7 9 23 46 0
    Time.utc 2012 7 10 0 0 0
    CronSchedule.parse "0 */15 * * * *"
    CronSchedule 1 35185445863425 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_wrap_around_days_2:
  validate_next_run
    Time.utc 2012 7 9 23 45 0
    Time.utc 2012 7 10 0 20 0
    CronSchedule.parse "0 20-35/15 * * * *"
    CronSchedule 1 34360786944 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_wrap_around_days_3:
  validate_next_run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 0 20 15
    CronSchedule.parse "15/35 20-35/15 * * * *"
    CronSchedule 1125899906875392 34360786944 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_wrap_around_days_4:
  validate_next_run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 1 20 15
    CronSchedule.parse "15/35 20-35/15 1/2 * * *"
    CronSchedule 1125899906875392 34360786944 11184810 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_wrap_around_days_5:
  validate_next_run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 10 20 15
    CronSchedule.parse "15/35 20-35/15 10-12 * * *"
    CronSchedule 1125899906875392 34360786944 7168 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_wrap_around_days_6:
  validate_next_run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 11 1 20 15
    CronSchedule.parse "15/35 20-35/15 1/2 */2 * *"
    CronSchedule 1125899906875392 34360786944 11184810 2863311530 -9223372036854767618 -9223372036854775681

test_wrap_around_days_7:
  validate_next_run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 0 20 15
    CronSchedule.parse "15/35 20-35/15 * 9-20 * *"
    CronSchedule 1125899906875392 34360786944 -9223372036837998593 2096640 -9223372036854767618 -9223372036854775681

test_wrap_around_days_8:
  validate_next_run
    Time.utc 2012 7 9 23 35 51
    Time.utc 2012 7 10 0 20 15
    CronSchedule.parse "15/35 20-35/15 * 9-20 7 *"  // Jul
    CronSchedule 1125899906875392 34360786944 -9223372036837998593 2096640 128 -9223372036854775681

test_wrap_around_months_1:
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2012 8 9 0 0 0
    CronSchedule.parse "0 0 0 9 4-10 *"  // Apr-Oct
    CronSchedule 1 1 1 512 2032 -9223372036854775681

test_wrap_around_months_2:
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2012 8 1 0 0 0
    CronSchedule.parse  "0 0 0 */5 4,8,10 1"  // Apr,Aug,Oct Mon
    CronSchedule 1 1 1 2216757314 1296 2

test_wrap_around_months_3:
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2012 10 1 0 0 0
    CronSchedule.parse "0 0 0 */5 10 1"  // Oct Mon
    CronSchedule 1 1 1 2216757314 1024 2

test_wrap_around_years_1:
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2013 2 4 0 0 0
    CronSchedule.parse "0 0 0 * 2 1"  // Feb Mon
    CronSchedule 1 1 1 -9223372032559808514 4 2

test_wrap_around_years_2: // "0 0 0 * Feb Mon/2"
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2013 2 1 0 0 0
    CronSchedule.parse "0 0 0 * 2 1/2"  // Feb Mon
    CronSchedule 1 1 1 -9223372032559808514 4 42

test_wrap_around_minute_hour_day_month_year:
  validate_next_run
    Time.utc 2012 12 31 23 59 45
    Time.utc 2013 1 1 0 0 0
    CronSchedule.parse "0 * * * * *"
    CronSchedule 1 -8070450532247928833 -9223372036837998593 -9223372032559808514 -9223372036854767618 -9223372036854775681

test_leap_year: // "0 0 0 29 Feb ?"
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    Time.utc 2016 2 29 0 0 0
    CronSchedule.parse "0 0 0 29 2 *"  // Feb
    CronSchedule 1 1 1 536870912 4 -9223372036854775681

test_no_match_1:
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    null
    CronSchedule.parse "0 0 0 30 2 *"  // Feb
    CronSchedule 1 1 1 1073741824 4 -9223372036854775681

test_no_match_2:
  validate_next_run
    Time.utc 2012 7 9 23 35 0
    null
    CronSchedule.parse "0 0 0 31 4 *"  // Apr
    CronSchedule 1 1 1 2147483648 16 -9223372036854775681
