// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .implicit_import_test as pre
export *

main:
  // Core libraries must not be exported with `export *`.
  pre.List
