// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo --named_arg/int:
/*
      @ named-arg-def
        ^
  [named-arg-def, named-arg-body, named-arg-call]
*/
  print named_arg
/*      @ named-arg-body */

baz --other_arg/string="":
/*
      @ other-arg-def
        ^
  [other-arg-def, other-arg-body, other-arg-call]
*/
  print other_arg
/*      @ other-arg-body */

bar --flag/bool:
/*
      @ flag-def
       ^
  [flag-def, flag-body, flag-call]
*/
  print flag
/*      @ flag-body */

class MyClass:
  value/int
  constructor --.value --scale/int=1:
/*
                         @ scale-def
                           ^
  [scale-def, scale-body, scale-call]
*/
    this.value = value * scale
/*                       @ scale-body */
