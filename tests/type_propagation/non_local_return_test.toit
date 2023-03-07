// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple
  test_continue

test_simple:
  invoke:
    invoke:
      3.repeat:
        return 42
  unreachable

test_continue:
  invoke:
    3.repeat:
      continue.invoke "hest"

invoke [block]:
  return block.call
