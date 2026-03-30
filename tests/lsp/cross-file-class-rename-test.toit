// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .cross-file-class-rename-test-dep show Gadget
/*                                            @ show */

main:
  g := Gadget
/*     @ use */
/*
       ^
  [def, type-param, type-return, ctor-call, show, use]
*/
  print g.value
