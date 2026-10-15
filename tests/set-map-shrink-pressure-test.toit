// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

main:
  run-all

run-all --heap-size/int=(256 * 1024) --slot-count/int=16384:
  set-max-heap-size_ heap-size
  [false, true].do: | map/bool |
    failures := 0
    48.repeat: | slack/int |
      if (run map (slack * 8) --slot-count=slot-count): failures++
    print "COLLECTION_SHRINK_PRESSURE map=$map failures=$failures successes=$(48 - failures) intact=true"
    expect (0 < failures < 48)

run map/bool slack/int --slot-count/int=16384 -> bool:
  keys := List 12: Key it
  values := List 12: ByteArray 8 --initial=it
  collection := map ? (Map 12 (: keys[it]) (: values[it])) : Set
  if not map: keys.do: collection.add it
  4.repeat: collection.remove keys[it]
  slots := List slot-count
  warm-stack 64
  filled := 0
  exhausted := catch:
    while filled < slots.size:
      slots[filled] = ByteArray 8 --initial=42
      filled++
  if exhausted != "OUT_OF_MEMORY" and exhausted != "ALLOCATION_FAILED": throw "PRESSURE_NOT_REACHED"
  (min filled slack).repeat:
    filled--
    slots[filled] = null
  error := catch: collection.remove keys[4]
  slots.fill null
  system.process-stats --gc
  if error: expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
  target-remains := collection.contains keys[4]
  expect-equals (target-remains ? 8 : 7) collection.size
  12.repeat: | index/int |
    expect-equals (index >= 5 or (index == 4 and target-remains)) (collection.contains keys[index])
    if map and index >= 5: expect-equals values[index] collection[keys[index]]
    expect-equals index (keys[index] as Key).value
    values[index].do: expect-equals index it
  // Retry removal and exercise both lookup and mutation after the failed shrink.
  collection.remove keys[4]
  next := Key 99
  if map: collection[next] = #[99]
  else: collection.add next
  expect (collection.contains next)
  if map: expect-equals #[99] collection[next]
  7.repeat: | index/int | collection.remove keys[index + 5]
  expect-equals 1 collection.size
  collection.remove next
  expect collection.is-empty
  return error != null

class Key:
  value/int
  constructor .value:
  hash-code -> int: return value

warm-stack depth/int -> int:
  if depth == 0: return 0
  return 1 + (warm-stack (depth - 1))
