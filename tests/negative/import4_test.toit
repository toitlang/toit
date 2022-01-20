// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .import4_a as foo

foo:
  return "main"

main:
  "Don't use 'foo'."
