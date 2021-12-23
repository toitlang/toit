// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
