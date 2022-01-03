// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.pipe
import expect show *

main args:
  toitc := args[0]
  test_dir := args[1]
  snap := args[2]

  base64_response := pipe.backticks toitc snap "--serialize"
  pipe.backticks toitc snap "--deserialize"
      base64_response.trim
