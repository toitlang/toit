// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .utils

main args:
  out := run-toitp args ["--senders"] --filter="the-target"
  lines := out.split LINE-TERMINATOR
  expect-equals """Methods with calls to "the-target"[3]:""" lines[0]

  ["global-lazy-field", "global-fun", "foo"].do: |needle|
    expect
      lines.any: it.starts-with "$needle "
