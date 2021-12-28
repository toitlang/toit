// Copyright (C) 2021 Toitware ApS. All rights reserved.
// TEST_FLAGS: --show-package-warnings

import target.foo as target

class A implements target.I1:

main:
  a := A
