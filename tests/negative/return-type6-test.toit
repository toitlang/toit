// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..confuse

interface Inter:

class A:

class B implements Inter:

foo -> Inter:
  return confuse null

main:
  confuse A
  confuse B
  foo
