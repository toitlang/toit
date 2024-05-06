// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo -- --foo:
  unresolved

bar --foo --:
  unresolved

foo [--] [--foo]:
  unresolved

bar [--foo] [--]:
  unresolved

gee --

gee -- -> none:

gee ---> none:
