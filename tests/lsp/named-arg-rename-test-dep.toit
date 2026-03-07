// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo --named_arg/int --other_arg/string="":
/*
        ^
  4
*/
/*
                          ^
  3
*/
  print named_arg
  print other_arg

bar --flag/bool:
/*
       ^
  3
*/
  print flag

class MyClass:
  value/int
  constructor --.value --scale/int=1:
/*
                          ^
  3
*/
    this.value = value * scale
