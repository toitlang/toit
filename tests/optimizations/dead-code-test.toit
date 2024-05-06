// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot
import expect show *

main args:
  snap := run args --entry-path="///untitled" {
    "///untitled": """
    foo:
      return 1
      foo

    main:
      print foo
    """
  }

  program := snap.decode
  methods := extract-methods program ["foo"]
  method := methods["foo"]
  return-count := 0
  method.do-bytecodes:
    expect it.name != "INVOKE_STATIC"
