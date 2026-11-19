// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

/**
Records the old size that the hash-find intrinsic passes to the rebuild block
  when the index is full.
*/
class RecordingMap extends Map:
  old-sizes := []

  rebuild_ old-size --allow-shrink/bool:
    // The intrinsic calls the rebuild block after the not-found block added
    //   the new entry, so the old size is one less than the current size.
    if not allow-shrink: old-sizes.add [old-size, size - 1]
    super old-size --allow-shrink=allow-shrink

class RecordingSet extends Set:
  old-sizes := []

  rebuild_ old-size --allow-shrink/bool:
    if not allow-shrink: old-sizes.add [old-size, size - 1]
    super old-size --allow-shrink=allow-shrink

main:
  map := RecordingMap
  1000.repeat: map[it] = it
  check map.old-sizes
  1000.repeat: expect-equals it map[it]

  set := RecordingSet
  1000.repeat: set.add it
  check set.old-sizes
  1000.repeat: expect (set.contains it)

check old-sizes/List:
  expect old-sizes.size > 0
  old-sizes.do: | pair |
    expect-equals pair[1] pair[0]
