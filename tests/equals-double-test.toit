// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  // TODO(florian): replace the inf and NaN construction once these constants
  // are available in the library.
  inf := 1.0
  310.repeat: inf *= 10
  nan := inf + (-inf)
  print inf
  print nan
