// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.pipe
import expect show *

main args:
  run_image := args[0]
  image := args[1]
  output := pipe.backticks run_image image
  expect_equals "Hello World\n" output
