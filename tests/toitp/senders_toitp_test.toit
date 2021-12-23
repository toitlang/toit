// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import .utils

main args:
  out := run_toitp args ["--senders", "the_target"]
  lines := out.split "\n"
  expect_equals """Methods with calls to "the_target"[3]:""" lines[0]

  ["global_lazy_field", "global_fun", "foo"].do: |needle|
    expect
      lines.any: it.starts_with "$needle "
