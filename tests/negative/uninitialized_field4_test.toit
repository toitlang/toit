// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class B:
  // Tests that we don't try to print an invalid field name in an
  //   error message.
  := ?
  / int ::= ?

main:
  b := B
