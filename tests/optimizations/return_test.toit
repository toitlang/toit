// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

main args:
  snap := run args --entry_path="///untitled" {
    "///untitled": """
    foo:
      return
        if Time.now.s_since_epoch == 0:
          0
        else:
          1
    main:
      print foo
    """
  }

  program := snap.decode
  methods := extract_methods program ["foo"]
  method := methods["foo"]
  return_count := 0
  method.do_bytecodes:
    if it.name == "RETURN": return_count++
  expect_equals 2 return_count
