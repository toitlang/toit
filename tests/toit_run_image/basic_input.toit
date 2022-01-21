// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import writer show Writer

main:
  stdout := Writer pipe.stdout
  stdout.write "Hello World\n"
