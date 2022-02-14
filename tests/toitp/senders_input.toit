// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

the_target:

class A:
  foo: the_target

global_lazy_field := the_target

global_fun:
  the_target

main:
  (A).foo
  global_lazy_field
  global_fun
