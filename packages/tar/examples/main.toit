// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import ...host.src.file as file
import tar show *

main:
  tar := Tar (file.Stream "/tmp/toit.tar" file.CREAT | file.WRONLY 0x1ff)
  tar.add "test2.txt" "456\n"
  tar.add "012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789" "123\n"
  tar.close
