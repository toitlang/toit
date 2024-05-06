// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system show process-stats

provoke-weak-processing:
  process-stats --gc  // Cause full GC.

main:
  test-map
  test-some-survive
  test-large-map
  test-reachable-through-keys
  test-dead-maps
  test-revived-maps

populate map/Map:
  10.repeat:
    map[it] = "String number $it"

// Simple test.
test-map:
  weak := Map.weak
  3.repeat:
    populate weak
    expect-equals 10 weak.size
    expect-equals "String number 0" weak[0]
    expect-equals "String number 9" weak[9]

    // All strings are unreachable, so they should be collected and zapped in the map.
    provoke-weak-processing

    expect-equals 10 weak.size
    expect-equals null weak[0]
    expect-equals null weak[9]

    sleep-until: weak.size == 0

    expect (not weak.contains 0)
    expect (not weak.contains 9)

// Test that values survive if they are reachable in other ways.
test-some-survive:
  weak := Map.weak
  3.repeat: | iteration |
    populate weak
    expect-equals 10 weak.size
    expect-equals "String number 0" weak[0]
    expect-equals "String number 9" weak[9]

    keep-me-alive := weak[iteration]

    // Most strings are unreachable, so they should be collected and zapped in the map.
    provoke-weak-processing

    expect-equals 10 weak.size
    expect-equals "String number $iteration" weak[iteration]
    expect-equals null weak[8]
    expect-equals null weak[9]

    sleep-until: weak.size == 1

    expect-equals "String number $iteration" weak[iteration]
    expect (not weak.contains 8)
    expect (not weak.contains 9)

populate-large weak/Map:
  // Use list to keep things from being zapped already while we build up the
  // weak map.
  keep-alive := List 1000: "String number $it"
  1000.repeat:
    weak[it] = keep-alive[it]

// Test that this all works when the map is so large that its backing is a
// large array containing arraylets.
test-large-map:
  weak := Map.weak
  populate-large weak

  expect-equals "String number 42" weak[42]
  expect-equals "String number 942" weak[942]

  provoke-weak-processing

  expect-equals null weak[42]
  expect-equals null weak[942]
  expect-equals 1000 weak.size

  sleep-until: weak.size == 0

  expect (not weak.contains 42)
  expect (not weak.contains 942)

// Test that values are zapped even if they are reachable through keys.
test-reachable-through-keys:
  weak := Map.weak

  10.repeat:
    str := "String number $it"
    weak[str] = str

  expect-equals 10 weak.size
  expect-equals "String number 4" weak["String number 4"]

  provoke-weak-processing

  expect-equals 10 weak.size
  expect-equals null weak["String number 4"]

  sleep-until: weak.size == 0

  expect (not weak.contains "String number 4")

// Test that weak maps that are GCed are handled correctly.
test-dead-maps:
  1000.repeat:
    weak := Map.weak
    populate weak
    expect-equals 10 weak.size
    expect-equals "String number 4" weak[4]

class Notifier:
  notified := false
  map/Map? := null

class Reviver:
  weak/Map
  notifier/Notifier

  constructor .weak .notifier:
    add-finalizer this::
      notifier.notified = true
      notifier.map = weak

create-reviver notifier/Notifier:
  map := Map.weak
  populate map
  Reviver map notifier  // Created, but we don't save a reference anywhere.

// A finalizer can revive a weak map that was thought lost.
// Test that this does not cause a crash.
// The weak map has been completely emptied in this case, and it lost its weakness.
test-revived-maps:
  notifier := Notifier

  create-reviver notifier

  expect-equals false notifier.notified

  provoke-weak-processing

  sleep-until: notifier.notified

  map := notifier.map

  // The map is empty, but no longer weak after its near death experience.

  expect-equals 0 map.size
  expect (not map.contains 0)

  populate map

  provoke-weak-processing

  sleep-until: map.size == 10

  expect-equals "String number 7" map[7]

// Pause the main task until the finalizer task has had time to satisfy the
// condition in the given block.
sleep-until [block]:
  with-timeout --ms=2000:
    while not block.call:
      sleep --ms=1
