// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

main:
  // TODO(florian): replace the inf and NaN construction once these constants
  // are available in the library.
  inf := 1.0
  310.repeat: inf *= 10
  nan := inf + (-inf)
  print inf
  print nan
