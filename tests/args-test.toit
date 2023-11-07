// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main args:
  expect-list-equals ["foo", "bar", "gee"] args
  expect-equals "[foo, bar, gee]" args.stringify
