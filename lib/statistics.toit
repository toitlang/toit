// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import core.utils
import math
import encoding.tison

/** Statistics utilities. */

/**
Online algorithm for computing simple statistics.

This uses Welford's online algorithm (see more here
  https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance).
*/
class OnlineStatistics:
  count_/int := 0
  mean_/float? := null
  m2_/float := 0.0
  min_/num? := null
  max_/num? := null


  /** Constructs an empty statistics. */
  constructor:

  /**
  Constructs statistics from the $bytes.

  Works with byte arrays generated by $to-byte-array.
  */
  constructor.from-byte-array bytes:
    os ::= tison.decode bytes
    assert: os is List and os.size == 5
    count_ = os[0]
    mean_ = os[1]
    m2_ = os[2]
    min_ = os[3]
    max_ = os[4]


  /** Updates the estimated variance with the $value. */
  update value/num:
    if not min_: min_ = value
    min_ = utils.min value min_

    if not max_: max_ = value
    max_ = utils.max value max_

    count_++
    if not mean_: mean_ = 0.0
    delta := value - mean_
    mean_ += delta / count_
    m2_ += delta * (value - mean_)

  /**
  Estimated sample variance of the collected values.

  Returns null if one or fewer values have been collected.
  */
  sample-variance -> float?:
    if count_ < 2:
      return null
    else:
      return m2_ / (count_ - 1)

  /**
  Estimated population variance of the collected values.

  Returns null if one or fewer values have been collected.
  */
  population-variance -> float?:
    if count_ < 2:
      return null
    else:
      return m2_ / count_

  /**
  Mean of the collected values.

  Returns null if no values have been collected.
  */
  mean -> float?:
    return mean_

  /**
  Minimum of the collected values.

  Returns null if no values have been collected.
  */
  min -> num?:
    return min_

  /**
  Maximum of the collected values.

  Returns null if no values have been collected.
  */
  max -> num?:
    return max_

  /** Count of the collected values. */
  count -> int:
    return count_


  /** Serializes the OnlineStatistics. */
  to-byte-array -> ByteArray:
    return tison.encode [count_, mean_, m2_, min_, max_]

  /** See $super. */
  operator == other/any -> bool:
    return other is OnlineStatistics
        and other.count_ == count_
        and other.mean_ == mean_
        and other.m2_ == m2_
        and other.min_ == min_
        and other.max_ == max_
