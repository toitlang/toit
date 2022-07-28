// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some_global := some_global + 1
some_global2 := store_lambda:: some_global2  // A lambda is allowed.
some_global3 := just_block: some_global3

store_lambda fun/Lambda: return 499
just_block [block]: return 42

main:
  some_global
  some_global2
  some_global3
