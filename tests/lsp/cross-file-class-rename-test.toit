// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .cross-file-class-rename-test-dep show Gadget
/*                                            @ show */
import .cross-file-class-rename-test-dep as dep

main:
  g := Gadget
/*
       @ use
       ^
  [def, type-param, type-return, ctor-call, show, use, prefixed-args, prefixed-noargs]
*/
  print g.value
  a := dep.Gadget 1
/*
           @ prefixed-args
           ^
  [def, type-param, type-return, ctor-call, show, use, prefixed-args, prefixed-noargs]
*/
  b := dep.Gadget
/*
           @ prefixed-noargs
           ^
  [def, type-param, type-return, ctor-call, show, use, prefixed-args, prefixed-noargs]
*/
