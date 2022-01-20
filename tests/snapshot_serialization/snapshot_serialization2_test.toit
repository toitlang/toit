// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import expect show *

main args:
  toitc := args[0]
  test_dir := args[1]
  snap := args[2]

  base64_response := pipe.backticks toitc snap "--serialize"
  pipe.backticks toitc snap "--deserialize"
      base64_response.trim
