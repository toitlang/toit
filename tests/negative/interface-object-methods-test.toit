// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// This is a positive test.
// We want to make sure that the type-checker doesn't complain when
// we use `Object` methods on interfaces.

import expect show *

interface I:

class A implements I:

create-I -> I: return A

main:
  a := create-I
  expect a == a
  str := a.stringify
  expect (str.starts-with "an instance")

  exit 1
