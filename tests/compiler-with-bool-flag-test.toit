// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo --bool-flag:

class A:
  constructor:
    // We run through the AST to see whether there is a return (making
    //   it a factory).
    // The traverse visitor was not checking correctly, if a value for
    //   the named argument was given.
    foo --bool-flag

main:
  a := A
