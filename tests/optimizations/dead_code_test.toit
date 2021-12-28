// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
