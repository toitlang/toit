// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor show Channel
import system

main:
  test-allocation-free-receive
  [1, 3, 5].do: test-retention it

publish channel/Channel witnesses/Map first/int count/int -> none:
  count.repeat:
    value := ByteArray 128 --initial=((first + it) & 255)
    witnesses[first + it] = value
    if it % 2 == 0: channel.send value
    else: expect (channel.try-send value)

consume channel/Channel first/int count/int -> none:
  count.repeat:
    value/ByteArray := channel.receive --blocking=(it % 2 == 0)
    expect-equals ((first + it) & 255) value[0]

test-retention capacity/int -> none:
  channel := Channel capacity
  witnesses := Map.weak
  10.repeat: | cycle |
    first := cycle * capacity
    publish channel witnesses first capacity
    system.process-stats --gc
    capacity.repeat: expect ((witnesses.get (first + it)) != null)
    consume channel first 1
    system.process-stats --gc
    expect-null (witnesses.get first)
    (capacity - 1).repeat: expect ((witnesses.get (first + 1 + it)) != null)
    consume channel (first + 1) (capacity - 1)
    system.process-stats --gc
    capacity.repeat: expect-null (witnesses.get (first + it))
    expect-equals 0 channel.size
    expect-null (channel.receive --blocking=false)

test-allocation-free-receive -> none:
  channel := Channel 256
  256.repeat: channel.send it
  stats := List 11
  system.process-stats stats
  before := stats[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP]
  256.repeat: channel.receive --blocking=false
  system.process-stats stats
  expect-equals before stats[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP]
