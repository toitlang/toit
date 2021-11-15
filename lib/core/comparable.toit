// Copyright (C) 2021 Toitware ApS. All rights reserved.

interface Comparable:
  /**
  Compares this object to the $other.

  Returns 1 if this is greater than the $other.
  Returns 0 if this is equal to the $other.
  Returns -1 if this is less than the $other.

  # Inheritance
  Subclasses may tighten the $other's type so it is the same
    as this class.
  */
  compare_to other/Comparable

  /**
  Variant of $(compare_to other).

  Calls $if_equal if this and $other are equal. Then returns the
    result of the call.

  # Examples
  In the example, `MyTime` implements a lexicographical ordering of seconds
    and nanoseconds using $(compare_to other [--if_equal]) to move on to
    nanoseconds when the seconds component is equal.
  ```
  class MyTime:
    seconds/int
    nanoseconds/int

    constructor .seconds .nanoseconds:

    compare_to other/MyTime -> int:
      return seconds.compare_to other.seconds --if_equal=:
        nanoseconds.compare_to other.nanoseconds
  ```
  */
  compare_to other/Comparable [--if_equal]
