// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .cross-file-class-rename-test-dep show Gadget

main:
  g := Gadget
/*
       ^
  5
*/
  print g.value
