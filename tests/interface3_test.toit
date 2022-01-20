// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

interface A:
  foo

class A_Base implements A:
  foo:

class B extends A_Base:

foo a/A: expect a is A

main:
  foo B
