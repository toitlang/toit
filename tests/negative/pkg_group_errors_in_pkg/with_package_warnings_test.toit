// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --show-package-warnings

import target.foo as target

class A implements target.I1:

main:
  a := A
