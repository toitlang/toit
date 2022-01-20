// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import target.foo as target

main:
  print "should be no warnings, as they are in the package"
  print target.say_hi
  exit 1
