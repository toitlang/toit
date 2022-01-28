// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .non_existing show A

class B:
  foo:

main:
  b := B
  b.bar  // Bad.
