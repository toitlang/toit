// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import foo-other-name
import expect show *

main:
  expect-equals "foo" foo-other-name.identify
