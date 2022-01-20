// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  // The compiler used to crash when there was a block
  // in receiver position.
  (: it).call 499
