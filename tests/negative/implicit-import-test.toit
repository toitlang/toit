// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .implicit-import-test as pre
export *

main:
  // Core libraries must not be exported with `export *`.
  pre.List
