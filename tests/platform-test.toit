// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

main:
  p/string := system.platform
  a/string := system.architecture
  expect p.size >= 3
  expect a.size >= 3
  print "$p $a"
