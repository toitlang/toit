// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..confuse

class A:
class B:

bar -> any: return null

// Tests that the error message is on `a` and not `b`.
foo a/A=bar b/B=(confuse a):

main:
  foo null
