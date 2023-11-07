// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

main args:
  snap := run args --entry-path="///untitled" {
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
  methods := extract-methods program ["foo"]
  method := methods["foo"]
  return-count := 0
  method.do-bytecodes:
    if it.name == "RETURN": return-count++
  expect-equals 2 return-count
