// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo -> none:
  return 499

bar:
  foo.call-on-none

gee:
  bar.call-on-none

main:
  bar
  unresolved
