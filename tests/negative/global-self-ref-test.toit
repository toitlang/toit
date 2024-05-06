// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some-global /int := some-global + 1
some-global2 /int := store-lambda:: some-global2  // A lambda is allowed.
some-global3 /int := just-block: some-global3

store-lambda fun/Lambda: return 499
just-block [block]: return 42

main:
  some-global
  some-global2
  some-global3
