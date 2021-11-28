// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/** A class representing a cron schedule */
class CronSchedule:

  // Each int represents a 64 bit pattern with a 1 in the positions corresponding to
  // the applicable times. The top most bit is set, if a * is found in the original cron expression.
  //
  // Examples:
  //   second = 107 = 0...01101011 corresponding to seconds 0, 1, 3, 5, 6
  //   dow = 36893488147419103487 = 1...01111111 corresponding to all weekdays
  //
  // Note that each unit uses only a subset of the 64 bits, see the bounds below.

  second/int ::= 0 // Bounds [0, 59]
  minute/int ::= 0 // Bounds [0, 59]
  hour/int ::= 0   // Bounds [0, 23]
  dom/int ::= 0    // Bounds [1, 31]
  month/int ::= 0  // Bounds [1, 12]
  dow/int ::= 0    // Bounds [0, 6]

  constructor .second .minute .hour .dom .month .dow:

  constructor.from_map map/Map:
    second = map["second"]
    minute = map["minute"]
    hour   = map["hour"]
    dom    = map["day_of_month"]
    month  = map["month"]
    dow    = map["day_of_week"]

  /** Constructs a CronScheduler based on parsing the description:
      1: either a predefined schedule "@name"
      2: or a six field format "secs mins hours days-of-month months week-days"
        - secs     -> 0-59 * , -
        - mins     -> 0-59 * , -
        - hours    -> 0-23 * , -
        - days     -> 1-31 * , -
        - months   -> 1-12 * , -
        - weekdays -> 0-6  * , -
  */
  constructor.parse description/string:
    if description.is_empty: throw "Cron: empty string"
    if description[0] == '@':
      description = get_predefined_description_ description
    fields ::= description.split " "
    if fields.size != 6: throw "Cron: expected six fields"
    return CronSchedule
      parse_field_ fields[0] 0 59
      parse_field_ fields[1] 0 59
      parse_field_ fields[2] 0 23
      parse_field_ fields[3] 1 31
      parse_field_ fields[4] 1 12
      parse_field_ fields[5] 0  6

  as_map:
    return {
      "second": second,
      "minute": minute,
      "hour": hour,
      "day_of_month": dom,
      "month": month,
      "day_of_week": dow,
    }

  stringify:
    return "CronSchedule $second $minute $hour $dom $month $dow"

  /**
    Returns the next time this schedule is activated, greater than the given time.
    Returns null if no time can be found within 5 years from the given time.

    (Implementation of: https://github.com/robfig/cron/blob/master/spec.go. Note we do not
    take into account time zones and daylight savings time.)
  */
  next t/Time -> Time?:
    // Clear out the nanoseconds (including milli and microseconds).
    t = t.plus --ns=-t.ns_part

    // Add 1 second (as the earliest possible time).
    t = t.plus --s=1

    // This flag indicates whether a field has been incremented
    added := false

    // If no time is found within five years, return zero.
    limit := (t.utc.plus --years=5).time

    while t < limit:
      start_over := false

      // Find the first applicable month.
      while not (month_matches_ t):
        if not added:
          added = true
          t = (t.utc.with --s=0 --m=0 --h=0 --day=1).time

        t = (t.utc.plus --months=1).time

        if t.utc.month == 2:
          start_over = true
          break

      if start_over:
        continue

      // Find the first applicable day.
      // Note: We do not handle daylight savings regimes where midnight does not exist.
      while not (day_matches_ t):
        if not added:
          added = true
          t = (t.utc.with --s=0 --m=0 --h=0).time

        t = (t.utc.plus --days=1).time

        if t.utc.day == 1:
          start_over = true
          break

      if start_over:/// Parse field
      // Find the first applicable hour.
      while not (hour_matches_ t):
        if not added:
          added = true
          t = (t.utc.with --s=0 --m=0).time

        t = t.plus --h=1

        if t.utc.h == 0:
          start_over = true
          break

      if start_over:
        continue

      // Find the first applicable minute.
      while not (minute_matches_ t):
        if not added:
          added = true
          t = (t.utc.with --s=0).time

        t = t.plus --m=1

        if t.utc.m == 0:
          start_over = true
          break

      if start_over:
        continue

      // Find the first applicable second.
      while not (second_matches_ t):
        if not added:
          added = true

        t = t.plus --s=1

        if t.utc.s == 0:
          start_over = true
          break

      if start_over:
        continue

      return t

    // If no time is found within five years, return null.
    return null

  month_matches_ t/Time -> bool:
    return (((1 << t.utc.month) & month) != 0)

  day_matches_ t/Time -> bool:
    dom_match := ((1 << t.utc.day) & dom) != 0
    dow_match := ((1 << (t.utc.weekday % 7)) & dow) != 0
    if (dom & STAR_BIT != 0) or (dow & STAR_BIT != 0):
      return dom_match and dow_match
    return dom_match or dow_match

  hour_matches_ t/Time -> bool:
    return (((1 << t.utc.h) & hour) != 0)

  minute_matches_ t/Time -> bool:
    return (((1 << t.utc.m) & minute) != 0)

  second_matches_ t/Time -> bool:
    return (((1 << t.utc.s) & second) != 0)

  static STAR_BIT ::= 1 << 63

  /// Lookup predefined crontab descriptions.
  static get_predefined_description_ keyword/string -> string:
    if keyword == "@yearly" or keyword == "@annually": return  "0 0 0 1 1 *"
    if keyword == "@monthly": return "0 0 0 1 * *"
    if keyword == "@weekly":  return "0 0 0 * * 0"
    if keyword == "@daily":   return "0 0 0 * * *"
    if keyword == "@hourly":  return "0 0 * * * *"
    throw "Cron: unknown predefined $keyword"

  /// Parse field: comma separated ranges and merge the results.
  static parse_field_ field/string min/int max/int -> int:
    result := 0
    field.split ",": result |= parse_range_ it min max
    return result

  /// Parse range: cardinal | cardinal "-" cardinal [ "/" cardinal ].
  static parse_range_ range/string min/int max/int -> int:
    range_and_step ::= range.split "/"
    low_and_high   ::= range_and_step[0].split "-"
    single_digit   ::= low_and_high.size == 1
    start := 0
    end := 0
    extra := 0
    if low_and_high[0] == "*":
      start = min
      end = max
      extra = STAR_BIT
    else:
      start = parse_cardinal_ low_and_high[0]
      if low_and_high.size == 1: end = start
      else if low_and_high.size == 2:
        end = parse_cardinal_ low_and_high[1]
      else: throw "Cron: too many hyphens: $range"
    step := 0
    if range_and_step.size == 1: step = 1
    else if range_and_step.size == 2:
      step = parse_cardinal_ range_and_step[1]
      if single_digit: end = max
      if step > 1: extra = 0
    else: throw "Cron: too many slashes: $range"
    if start < min: throw "Cron: beginning of range $start below min $min"
    if end   > max: throw "Cron: end of range $end above max $max"
    if start > end: throw "Cron: beginning of range $start beyond end of range $end"
    if step == 0:   throw "Cron: step of range should be a positive number $step"
    return (step_bits_ start end step) | extra

  /// Parse a non-negative integer.
  static parse_cardinal_ number/string -> int:
    value ::= int.parse number --on_error=: throw "Cron: cannot parse $number as integer"
    if value < 0: throw "Cron: parsed integer $number is negative"
    return value

  /// Compute step bit pattern,
  static step_bits_ min/int max/int step/int -> int:
    bits := 0
    for i := min; i <= max; i += step: bits |= 1 << i
    return bits
