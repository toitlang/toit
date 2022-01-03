// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.pipe
import writer show Writer

main:
  stdout := Writer pipe.stdout
  stdout.write "Hello World\n"
