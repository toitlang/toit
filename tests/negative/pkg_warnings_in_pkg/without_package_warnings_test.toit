// Copyright (C) 2021 Toitware ApS. All rights reserved.

import target.foo as target

main:
  print "should be no warnings, as they are in the package"
  print target.say_hi
  exit 1
