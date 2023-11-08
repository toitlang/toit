// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// The `-Werror` should not matter, as the warnings are in the package.
// TEST_FLAGS: -Werror

import target.foo as target

main:
  print "should be no warnings, as they are in the package"
  print target.say-hi
  exit 1
