// Copyright (C) 2018 Toitware ApS. All rights reserved.

import .ambiguous_a
import .ambiguous_b

bar f:
  f.call

main:
  bar:: foo  // Ambiguous import.
