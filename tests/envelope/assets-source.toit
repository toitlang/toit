// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.assets

main:
  decoded := assets.decode
  print decoded["message"].to-string
  print decoded["message2"].to-string
