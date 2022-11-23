// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.tison
import .time_impl_

/**
Support for time and durations.

The $Duration class represents relative times. That is, the time elapsed
  between two points in time.

The $Time class represents the wallclock time as an Epoch time (read more:
  https://en.wikipedia.org/wiki/Unix_time).
The $TimeInfo class is a human-friendly decomposition of a $Time instance.

# Examples
```
main:
  // In this example, we assume the time is 2021-04-21 15:30:35 UTC.
  now := Time.now
  // By default a time is stringified to UTC.
  print now         // >> 2021-04-21T15:30:35Z.
  print now.utc     // >> 2021-04-21T15:30:35Z.
  print now.local   // >> 2021-04-21T17:30:35.
  print now.local.h // >> 17.

  summing_duration := Duration.of:
    sum := 0
    1000.repeat: sum += it
    print sum  // >> 499500.
  print summing_duration // Prints the duration. For example: 1.118ms.
```
*/

/**
A Duration, capturing relative times.

Durations can be negative.
Durations are limited to ~292 years (signed 64 bit nanoseconds).
*/
class Duration implements Comparable:

  /** The number of nanoseconds per microsecond. */
  static NANOSECONDS_PER_MICROSECOND /int ::=            1_000
  /** The number of nanoseconds per millisecond. */
  static NANOSECONDS_PER_MILLISECOND /int ::=        1_000_000
  /** The number of nanoseconds per second. */
  static NANOSECONDS_PER_SECOND /int      ::=    1_000_000_000
  /** The number of nanoseconds per minute. */
  static NANOSECONDS_PER_MINUTE /int      ::=   60_000_000_000
  /** The number of nanoseconds per hour. */
  static NANOSECONDS_PER_HOUR /int        ::= 3600_000_000_000

  /** The number of microseconds per millisecond. */
  static MICROSECONDS_PER_MILLISECOND /int ::=        1_000
  /** The number of microseconds per second. */
  static MICROSECONDS_PER_SECOND /int      ::=    1_000_000
  /** The number of microseconds per minute. */
  static MICROSECONDS_PER_MINUTE /int      ::=   60_000_000
  /** The number of microseconds per hour. */
  static MICROSECONDS_PER_HOUR /int        ::= 3600_000_000

  /** The number of milliseconds per second. */
  static MILLISECONDS_PER_SECOND /int ::=    1_000
  /** The number of milliseconds per minute. */
  static MILLISECONDS_PER_MINUTE /int ::=   60_000
  /** The number of milliseconds per hour. */
  static MILLISECONDS_PER_HOUR /int   ::= 3600_000

  /** The number of seconds per minute. */
  static SECONDS_PER_MINUTE /int ::=   60
  /** The number of seconds per hour. */
  static SECONDS_PER_HOUR /int   ::= 3600

  ns_ /int

  /**
  Constructs a duration of $h hours, $m minutes, $ms milliseconds, $us
    microseconds, and $ns nanoseconds.
  */
  constructor --h/int=0 --m/int=0 --s/int=0 --ms/int=0 --us/int=0 --ns/int=0:
    ns_ = ns
        + (us * NANOSECONDS_PER_MICROSECOND)
        + (ms * NANOSECONDS_PER_MILLISECOND)
        + (s  * NANOSECONDS_PER_SECOND)
        + (m  * NANOSECONDS_PER_MINUTE)
        + (h  * NANOSECONDS_PER_HOUR)

  /**
  Constructs a duration of $ns_ nanoseconds.
  */
  constructor .ns_/int:

  /**
  Calls the given $block and measures the duration of the call.

  # Aliases
  - `Stopwatch`: Dart
  - `Date` difference: JavaScript
  */
  constructor.of [block]:
    start ::= Time.monotonic_us
    block.call
    ns_ = (Time.monotonic_us - start) * 1000

  /**
  Constructs a duration from the given $time to now ($Time.now).

  For times in the past ($time < $Time.now), this constructs a positive duration.

  This operation is equivalent to `time.to_now` which is preferred, unless
    the developer wants to emphasize the $Duration type.
  */
  constructor.since time/Time:
    now := Time.now
    ns_ = (now.seconds_ - time.seconds_) * Duration.NANOSECONDS_PER_SECOND + (now.ns_ - time.ns_)

  /**
  Constructs a duration from now ($Time.now) to the given $time.

  For times in the future ($Time.now < $time), this constructs a positive duration.

  # Examples
  ```
  main:
    // In this example, we assume the time is 2021-04-21 15:30:35 UTC.
    time := Time.utc --year=2021 --month=04 --day=21 --h=17 --m=45 --s=35b
    print
      Duration.until time  // >> 2h15m0s

    time = Time.utc --year=2021 --month=04 --day=21 --h=14 --m=45 --s=35b
    print
      Duration.until time  // >> -45m0s
  ```
  */
  constructor.until time/Time:
    now := Time.now
    ns_ = (time.seconds_ - now.seconds_) * Duration.NANOSECONDS_PER_SECOND + (time.ns_ - now.ns_)

  /**
  Calls the given $block periodically.

  # Advanced
  Ensures that two executions of the block are always spaced out by
    *at least* this duration. At the end of every call of the block
    sleeps the remaining amount of this duration.
  If an execution took longer than the period, skips one cycle. For example,
    if the block was supposed to run every 5ms, but the the first execution
    took 7ms, then this function sleeps 3ms, before it calls the block again
    at the next cycle (10ms).

  This function may drift. If the start of the block is delayed
    (because of imprecision, or because the system was busy), then the
    subsequent executions will never catch up with the original schedule.
  */
  periodic [block] -> none:
    while true:
      run_time := Duration.of block
      // If runtime passes period we skip to start of period.
      sleep (Duration ns_ - run_time.ns_ % ns_)

  /**
  The absolute value of this duration.
  */
  abs -> Duration:
    if ns_ == int.MIN: throw "OUT_OF_RANGE"
    if ns_ < 0: return Duration --ns=-ns_
    return this

  /**
  See $super.

  Returns the duration in a compact string format, without loss of precision.
  For example, the duration equal to 1234567890us:
    `20m34.56789s`.
  */
  stringify:
    // Inspired by time.Duration.String() from Golang.
    // https://golang.org/src/time/time.go?s=21836:21869#L604

    // "Largest" duration is of the format -2540400h10m10.000000000s, 25 bytes long.
    buffer := ByteArray 25
    index := buffer.size

    value := ns_.abs

    print_char := : | c |
      index--
      buffer[index] = c

    print_int := : | i |
      fraction := i.stringify
      index -= fraction.size
      buffer.replace index fraction

    // Print a fraction to the buffer. Any trailing '0's are skipped.
    print_fraction := : | f digits |
      found_non_zero := false
      digits.repeat:
        digit := f % 10
        f /= 10
        if digit != 0 or found_non_zero:
          found_non_zero = true
          print_char.call '0' + digit
      if found_non_zero: print_char.call '.'
      f

    print_char.call 's'

    if value == 0:
      return "0s"
    else if value == 0x8000_0000_0000_0000:
      // Edge case. This number is possible to represent as the positive-signed counterpart
      // as int64.
      return "-2562047h47m16.854775808s"
    else if value < NANOSECONDS_PER_SECOND:
      if value < NANOSECONDS_PER_MICROSECOND:
        print_char.call 'n'
      else:
        digits ::= ?
        if value < NANOSECONDS_PER_MILLISECOND:
          print_char.call 'u'
          digits = 3
        else:
          print_char.call 'm'
          digits = 6
        value = print_fraction.call value digits
      print_int.call value
    else:
      value = print_fraction.call value 9
      print_int.call value % 60

      // Minutes.
      value /= 60
      if value > 0:
        print_char.call 'm'
        print_int.call value % 60

        // Hours.
        value /= 60
        if value > 0:
          print_char.call 'h'
          print_int.call value

    if ns_ < 0: print_char.call '-'

    return buffer.to_string index buffer.size

  /**
  Whether this duration is equal to the $other.

  # Examples
  ```
  d_5ns := Duration --ns=5
  d_12s := Duration --s=12

  d_5ns == d_5ns  // => true
  d_12s == t_5ns  // => false
  ```
  */
  operator == other/Duration -> bool:
    return ns_ == other.ns_

  /**
  Whether this duration is less than the $other.

  # Examples
  ```
  d_5ns := Duration --ns=5
  d_12s := Duration --s=12

  d_5ns < d_5ns  // => false
  d_12s < d_5ns  // => false

  d_5ns < d_12s  // => true
  ```
  */
  operator < other/Duration -> bool:
    return ns_ < other.ns_

  /**
  Whether this duration is less than or equal to the $other.
  ```
  d_5ns := Duration --ns=5
  d_12s := Duration --s=12

  d_5ns <= d_5ns  // => true
  d_5ns <= d_12s  // => true

  d_12s <= d_5ns  // => false
  ```
  */
  operator <= other/Duration -> bool:
    return ns_ <= other.ns_

  /**
  Whether this duration is greater than the $other.

  # Examples
  ```
  d_5ns := Duration --ns=5
  d_12s := Duration --s=12

  d_5ns > d_5ns  // => false
  d_5ns > d_12s  // => false

  d_12s > d_5ns  // => true
  ```
  */
  operator > other/Duration -> bool:
    return ns_ > other.ns_

  /**
  Whether this duration is greater than or equal to the $other.

  # Examples
  ```
  d_5ns := Duration --ns=5
  d_12s := Duration --s=12

  d_5ns >= d_12s  // => false

  d_5ns >= d_5ns  // => true
  d_12s >= d_5ns  // => true
  ```
  */
  operator >= other/Duration -> bool:
    return ns_ >= other.ns_

  /**
  See $(Comparable.compare_to other).
  */
  compare_to other/Duration -> int:
    return ns_.compare_to other.ns_

  /**
  See $(Comparable.compare_to other [--if_equal]).
  */
  compare_to other/Duration [--if_equal] -> int:
    return ns_.compare_to other.ns_ --if_equal=if_equal

  // Accessors for various time units.
  /** This duration in nanoseconds. */
  in_ns -> int: return ns_
  /** This duration in microseconds. */
  in_us -> int: return ns_ / NANOSECONDS_PER_MICROSECOND
  /** This duration in milleseconds. */
  in_ms -> int: return ns_ / NANOSECONDS_PER_MILLISECOND
  /** This duration in seconds. */
  in_s  -> int: return ns_ / NANOSECONDS_PER_SECOND
  /** This duration in minutes. */
  in_m  -> int: return ns_ / NANOSECONDS_PER_MINUTE
  /** This duration in hours. */
  in_h  -> int: return ns_ / NANOSECONDS_PER_HOUR

  /** Whether this duration is 0 ($Duration.ZERO). */
  is_zero -> bool:
    return ns_ == 0

  /**
  Adds this duration to the $other duration.

  # Examples
  ```
  t_12s := Duration --s=12
  t_5s := Duration --s=5

  print t_12s + t_5s  // >> 17s

  t_42ns := Duration --ns=42

  print t_12s + t_42ns  // >> 12.000000042s
  ```
  */
  operator + other/Duration:
    return Duration ns_ + other.ns_

  /**
  Subtracts this duration from the $other duration.

  # Examples
  ```
  t_12s := Duration --s=12
  t_5s := Duration --s=5

  print t_12s - t_5s  // >> 7s
  print t_5s - t_12s  // >> -7s
  ```
  */
  operator - other/Duration:
    return Duration ns_ - other.ns_

  /**
  Negates this duration.

  # Examples
  ```
  t_5s := Duration --s=5

  print -t_5s    // >> -5s
  print -(-t_5)  // >> 5s
  ```
  */
  operator -:
    return Duration -ns_

  /**
  Multiplies this duration with the $factor.

  # Examples
  ```
  t_5s := Duration --s=5

  print t_5s * 2   // 10s
  print t_5s * -3  // -15s

  print 5 * t_5s  // Error, num's * does not know Duration!
  ```
  */
  operator * factor/num -> Duration:
    return Duration (factor * ns_).to_int

  /**
  Divides the duration by the $factor.

  # Example
  ```
  t_9s := Duration --s=9

  print t_9s / 3  // >> 3s
  ```
  */
  operator / factor/num -> Duration:
    return Duration (ns_ / factor).to_int

  /**
  A constant 0-duration singleton.

  Prefer to use this for 0-durations to avoid allocations.
  */
  static ZERO /Duration ::= Duration 0


/** A decomposed view of a $Time object. */
class TimeInfo:

  /** Weekday representation of Monday. */
  static MONDAY    ::= 1
  /** Weekday representation of Tuesday. */
  static TUESDAY   ::= 2
  /** Weekday representation of Wednesday. */
  static WEDNESDAY ::= 3
  /** Weekday representation of Thursday. */
  static THURSDAY  ::= 4
  /** Weekday representation of Friday. */
  static FRIDAY    ::= 5
  /** Weekday representation of Saturday. */
  static SATURDAY  ::= 6
  /** Weekday representation of Sunday. */
  static SUNDAY    ::= 7

  /** The corresponding time instance. */
  time /Time

  /** Year. */
  year /int

  /**
  Month of the year.
  In the range 1-12.
  */
  month /int

  /**
  Day of the month.
  In the range 1-31.
  */
  day /int

  /**
  Hours after midnight.
  In the range 0-23.
  */
  h /int

  /**
  Minutes after the hour.
  In the range 0-59.
  */
  m /int

  /**
  Seconds after the minute.
  Generally in the range 0 to 59. May be 60 in case of leap-seconds.
  */
  s /int

  /**
  Nanoseconds after the second.
  In the range 0-999_999_999.
  */
  ns /int

  /**
  Weekday.

  In accordance with ISO 8601, the week starts with Monday having the value 1.
  When using a weekday for indexing, it is often convenient to take the
    $weekday value module 7, which gives a value in the range 0 to 6, but shuffles
    Sunday down to the beginning of the week.
  */
  weekday /int

  /**
  Days since January 1st.
  In the range 1-366.
  In combination with the year also known as ordinal date.
  */
  // 0-365, days since January 1.
  yearday /int

  /** Whether this instance is in UTC. */
  is_utc /bool

  /** Whether this instance is computed with daylight saving active. */
  is_dst /bool

  constructor.__ .time --.is_utc:
    info := time_info_ time.s_since_epoch is_utc
    ns = time.ns_
    s = info[0]
    m = info[1]
    h = info[2]
    day = info[3]
    month = info[4] + 1  // Toit's months are 1-based.
    year = info[5]
    weekday = info[6] == 0 ? 7 : info[6]  // Toit starts weeks with Monday == 1.
    yearday = info[7]
    is_dst = info[8]

  /**
  Adds the given parameters to this time info.
  Takes daylight-saving changes into account. Adding a day is thus not always
    equivalent to adding 24 hours.
  */
  plus --years/int=0 --months/int=0 --days/int=0 --h/int=0 --m/int=0 --s/int=0 --ms/int=0 --us/int=0 --ns/int=0 -> TimeInfo:
    years += this.year
    months += this.month
    days += this.day
    h += this.h
    m += this.m
    s += this.s
    ns += this.ns
    new_time := Time.local_or_utc_
          years
          months
          days
          h
          m
          s
          --ms=ms
          --us=us
          --ns=ns
          --is_utc=is_utc
    return TimeInfo.__ new_time --is_utc=is_utc

  /** Creates a new $TimeInfo with the given parameters updated. */
  with --year/int=year --month/int=month --day/int=day --h/int=h --m/int=m --s/int=s --ns/int=ns --dst/bool?=null -> TimeInfo:
    new_time := Time.local_or_utc_
          year
          month
          day
          h
          m
          s
          --ms=0
          --us=0
          --ns=ns
          --is_utc=is_utc
          --dst=dst
    return TimeInfo.__ new_time --is_utc=is_utc

  /**
  Converts this instance to an string in ISO 8601 format.
  For example, the time of the first moonlanding would be written as:
    `1969-07-20T20:17:00Z`.
  */
  to_iso8601_string:
    return "$(year)-$(%02d month)-$(%02d day)T$(%02d h):$(%02d m):$(%02d s)$(is_utc ? "Z" : "")"

  /** See $super. */
  stringify -> string:
    return to_iso8601_string

/**
Stores the given $rules in the `TZ` environment variable and
  calls `tzset`, thus activating it.

Valid TZ values can be easily obtained by looking at the last line of the
  zoneinfo files on Linux machines:
```
tail -n1 /usr/share/zoneinfo/Europe/Copenhagen
```

# Examples
```
set_timezone "CET-1CEST,M3.5.0,M10.5.0/3"  // Central European Timezone (as of 2022).
set_timezone "PST8PDT,M3.2.0,M11.1.0"  // Pacific Time (as of 2022).
```
*/
set_timezone rules/string:
  #primitive.core.set_tz

/**
A wall clock time.

The wall clock time is represented as a Unix time (https://en.wikipedia.org/wiki/Unix_time).
  That is the time elapsed since 1970-01-01T00:00:00Z.
The time is measured down to nanoseconds.

If you need a decomposed view of a $Time, then convert it to a $TimeInfo
  instance with $local or $utc.
*/
class Time implements Comparable:

  seconds_ /int
  ns_      /int
  local_   /TimeInfo? := null
  utc_     /TimeInfo? := null

  /**
  Constructs a time instance from the given parameters.
  */
  constructor.epoch --h/int=0 --m/int=0 --s/int=0 --ms/int=0 --us/int=0 --ns/int=0:
    s += (h*60 + m) * 60
    ns += ms * Duration.NANOSECONDS_PER_MILLISECOND
    ns += us * Duration.NANOSECONDS_PER_MICROSECOND
    // Normalize if needed.
    seconds_ = s + ns / Duration.NANOSECONDS_PER_SECOND
    ns_ = ns % Duration.NANOSECONDS_PER_SECOND
    if ns_ < 0:
      // Ensure ns is non-negative.
      seconds_ -= 1
      ns_ += Duration.NANOSECONDS_PER_SECOND

  /**
  Constructs a time instance for the current moment in time.
  */
  constructor.now:
    pair ::= get_real_time_clock
    return Time.epoch --s=pair[0] --ns=pair[1]

  /**
  Constructs a time instance in local time.
  $dst can be used to force daylight saving. This is
    only interesting when the remaining values are ambiguous. For example,
    (most of) Europe changed to winter time on October 27 2019, at 3 a.m.
    The first time Europe observed 3 a.m. the clock was reset to 2 a.m.
    This means that a time like 2:30 a.m. is ambiguous, since it was observed
    twice. The $dst flag allows to disambiguate these
    cases. The flag should *not* be used otherwise.
  */
  constructor.local --year/int --month/int --day/int --h/int=0 --m/int=0 --s/int=0 --ms/int=0 --us/int=0 --ns/int=0 --dst/bool?=null:
    return Time.local_or_utc_ year month day h m s --ms=ms --us=us --ns=ns --is_utc=false --dst=dst

  /** Variant of $(Time.local --year --month --day --h --m --s --ms --us --ns --dst). */
  constructor.local year/int month/int day/int h/int=0 m/int=0 s/int=0 --ms/int=0 --us/int=0 --ns/int=0 --dst/bool?=null:
    return Time.local_or_utc_ year month day h m s --ms=ms --us=us --ns=ns --is_utc=false --dst=dst

  /** Constructs a time instance in UTC from the given parameters. */
  constructor.utc --year/int --month/int --day/int --h/int=0 --m/int=0 --s/int=0 --ms/int=0 --us/int=0 --ns/int=0:
    return Time.local_or_utc_ year month day h m s --ms=ms --us=us --ns=ns --is_utc=true

  /** Variant of $(Time.utc --year --month --day --h --m --s --ms --us --ns) */
  constructor.utc year/int month/int day/int h/int=0 m/int=0 s/int=0 --ms/int=0 --us/int=0 --ns/int=0:
    return Time.local_or_utc_ year month day h m s --ms=ms --us=us --ns=ns --is_utc=true

  /**
  Constructs a time instance in local time or UTC.

  The given $is_utc decides whether the instance is in local time or UTC.
  If the time is UTC, then the $dst parameter is ignored (see
    $(Time.local --year --month --day --h --m --s --ms --us --ns --dst) for
    more on the use of the $dst parameter).
  */
  constructor.local_or_utc_ year/int month/int day/int h/int m/int s/int --ms/int --us/int --ns/int --is_utc/bool --dst/bool?=null:
    ns += ms * Duration.NANOSECONDS_PER_MILLISECOND + us * Duration.NANOSECONDS_PER_MICROSECOND
    s += ns / Duration.NANOSECONDS_PER_SECOND
    ns = ns % Duration.NANOSECONDS_PER_SECOND
    if ns < 0:
      s--
      ns += Duration.NANOSECONDS_PER_SECOND
    // TODO(florian): take is_utc into account.
    if is_utc:
      seconds_ = seconds_since_epoch_utc_ year (month - 1) day h m s
    else:
      seconds_ = seconds_since_epoch_local_ year (month - 1) day h m s dst
    ns_ = ns

  /**
  Constructs a time instance from the given bytes.

  This operation is the inverse of $to_byte_array.
  */
  constructor.deserialize bytes/ByteArray:
    values := tison.decode bytes
    return Time.epoch --s=values[0] --ns=values[1]

  /**
  Parses the given $str to construct a UTC time instance.

  The $str must be in ISO 8601 format. For example "2019-12-18T06:22:48Z".
  */
  constructor.from_string str/string:
    is_utc := str.ends_with "Z"
    str = str.trim --right "Z"
    parts ::= str.split "T"
    str_to_int ::= :int.parse it --on_error=: throw "Cannot parse $it as integer"
    if parts.size != 2: throw "Expected T to separate date and time"
    date_parts ::= (parts[0].split "-").map str_to_int
    if date_parts.size != 3: throw "Expected 3 segments separated by - for date"
    time_parts ::= (parts[1].split ":").map str_to_int
    if time_parts.size != 3: throw "Expected 3 segments separated by : for time"
    return Time.local_or_utc_
      date_parts[0]
      date_parts[1]
      date_parts[2]
      time_parts[0]
      time_parts[1]
      time_parts[2]
      --ms=0
      --us=0
      --ns=0
      --is_utc=is_utc

  /**
  Returns a monotonic microsecond value.
  This clock source only increments and never jumps.
  The clock is not anchored and thus has no fixed relationship to the current
    time.

  If the system time is updated (for example because of an NTP adjustment),
    then this function is unaffected.
  */
  static monotonic_us -> int:
    #primitive.core.time

  /**
  See $super.

  Returns the string time in UTC.
  */
  stringify:
    return utc.stringify

  /** Whether this time is equal to the $other. */
  operator == other/Time -> bool:
    return seconds_ == other.seconds_ and ns_ == other.ns_

  /** Whether this time is before the $other. */
  operator < other/Time -> bool: return (compare_to other) < 0

  /** Whether this time is after the $other. */
  operator > other/Time -> bool: return (compare_to other) > 0

  /** Whether this time is before or at the same time as the $other. */
  operator <= other/Time -> bool: return (compare_to other) <= 0

  /** Whether this time is after or at the same time as the $other. */
  operator >= other/Time -> bool: return (compare_to other) >= 0

  /**
  Compares this time to the $other.

  Returns 1 if this time is after (greater than) the $other.
  Returns 0 if this time is equal to the $other.
  Returns -1 if this time is before (less than) the other.

  # Examples
  ```
  t0 := Time.epoch
  t1 := Time.epoch --h=1
  t2 := Time.epoch --h=2

  t0.compare_to t0  // => 0
  t1.compare_to t1  // => 0
  t2.compare_to t2  // => 0

  t0.compare_to t1  // => -1
  t1.compare_to t2  // => -1
  t0.compare_to t2  // => -1

  t2.compare_to t1  // => 1
  t1.compare_to t0  // => 1
  t2.compare_to t0  // => 1
  ```
  */
  compare_to other/Time -> int:
    if seconds_ < other.seconds_: return -1
    if seconds_ > other.seconds_: return 1
    if ns_ < other.ns_: return -1
    if ns_ > other.ns_: return 1
    return 0

  /**
  Variant of $(compare_to other).

  Calls $if_equal if this time is equal to the $other.
  */
  compare_to other/Time [--if_equal] -> int:
    result := compare_to other
    if result == 0: return if_equal.call
    return result

  /** Seconds since the epoch 1970-01-01T00:00:00Z. */
  s_since_epoch -> int:
    return seconds_

  /** Milliseconds since the epoch 1970-01-01T00:00:00Z. */
  ms_since_epoch -> int:
    return seconds_ * 1000 + ns_ / Duration.NANOSECONDS_PER_MILLISECOND

  /** Nanoseconds since the epoch 1970-01-01T00:00:00Z. */
  ns_since_epoch -> int:
    return seconds_ * Duration.NANOSECONDS_PER_SECOND + ns_

  /** The nanosecond component of this time. */
  ns_part -> int:
    return ns_

  /** The hashcode of this time. */
  hash_code -> int:
    return (seconds_ * 17) ^ ns_

  /** Adds the $duration to this time. */
  operator + duration/Duration -> Time:
    return Time.epoch
      --s=seconds_ + duration.in_s
      --ns=ns_ + duration.ns_ % Duration.NANOSECONDS_PER_SECOND

  /** Subtracts the $duration from this time. */
  operator - duration/Duration -> Time:
    return Time.epoch
        --s=seconds_
        --ns=(ns_ - duration.in_ns)

  /** Computes the duration from this time to the $other. */
  to other/Time -> Duration:
    sec_diff := other.seconds_ - seconds_
    ns_diff := other.ns_ - ns_
    return Duration sec_diff * Duration.NANOSECONDS_PER_SECOND + ns_diff

  /**
  Computes the duration from this time to now ($Time.now).

  # Examples
  ```
  main:
    // In this example, we assume the time is 2021-04-21 15:30:35 UTC.
    time := Time.utc --year=2021 --month=04 --day=21 --h=12 --m=30 --s=35
    print time.to_now  // >> 3h0m0s

    time = Time.utc --year=2021 --month=04 --day=21 --h=18 --m=30 --s=35
    print time.to_now  // >> --3h0m0s
  ```
  */
  to_now -> Duration:
    return Duration.since this

  /**
  Decomposes this time to a human-friendly version using the local time.
  */
  local -> TimeInfo:
    if not local_: local_ = TimeInfo.__ this --is_utc=false
    return local_

  /**
  Decomposes this time to a human-friendly version using UTC.
  */
  utc -> TimeInfo:
    if not utc_: utc_ = TimeInfo.__ this --is_utc=true
    return utc_

  /**
  Adds the given parameters.
  */
  plus --h/int=0 --m/int=0 --s/int=0 --ms/int=0 --us/int=0 --ns/int=0 -> Time:
    return Time.epoch --h=h --m=m --s=(s + seconds_) --ms=ms --us=us --ns=(ns + ns_)

  /**
  Converts this instance into a byte array.

  The returned byte array is a valid input for the constructor
    $Time.deserialize.
  */
  to_byte_array:
    return tison.encode [seconds_, ns_]
