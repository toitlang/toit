// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import target.foo as target

main:
  print "should still be a warning, as they are in a local package"
  print target.say-hi
  exit 1
