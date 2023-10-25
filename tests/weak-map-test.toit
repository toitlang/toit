// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

provoke-weak-processing:
  process-stats --gc  // Cause full GC.

main:
  test-map
  test-some-survive

populate map/Map:
  10.repeat:
    map[it] = "String number $it"

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

    sleep --ms=10  // Allow cleanup to happen.

    expect-equals 0 weak.size
    expect (not weak.contains 0)
    expect (not weak.contains 9)

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

    sleep --ms=10  // Allow cleanup to happen.

    expect-equals 1 weak.size
    expect-equals "String number $iteration" weak[iteration]
    expect (not weak.contains 8)
    expect (not weak.contains 9)
