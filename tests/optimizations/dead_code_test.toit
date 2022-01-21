// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot
import expect show *

main args:
  snap := run args --entry_path="///untitled" {
    "///untitled": """
    foo:
      return 1
      foo

    main:
      print foo
    """
  }

  program := snap.decode
  methods := extract_methods program ["foo"]
  method := methods["foo"]
  return_count := 0
  method.do_bytecodes:
    expect it.name != "INVOKE_STATIC"
