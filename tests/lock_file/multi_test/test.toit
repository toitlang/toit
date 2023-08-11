// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import redirected.target as redirected
import sub
import foo
import expect show *

// Tests that each package has its own prefixes.
// See the package.lock file.

main:
  expect-equals "foo" foo.identify
  expect-equals "target + foo.sub=(sub foo.target=target self.sub=(still self))" redirected.identify
  expect-equals "sub foo.target=target self.sub=(still self)" sub.identify
