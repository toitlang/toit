// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .cross-file-field-rename-test-dep show Settings

main:
  s := Settings
  s.is-paused = true
/*  @ assign */
/*
    ^
  [def, assign, read]
*/
  print s.is-paused
/*        @ read */
