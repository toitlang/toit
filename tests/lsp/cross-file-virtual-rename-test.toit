// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .cross-file-virtual-rename-test-dep show Animal Dog

call-it animal/Animal:
  animal.speak
/*
         ^
  4
*/

main:
  dog := Dog
  dog.speak
  call-it dog
