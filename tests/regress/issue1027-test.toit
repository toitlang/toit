// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  exception := catch: recurse
  expect-null exception  // The exception is turned into null by [execute].

recurse:
  value := execute --print-trace=true (:recurse): return null
  expect-null value
  return null  // TODO(florian,kasper): check missing return.

execute --print-trace=false [block] [fail-block]:
  catch
    --trace=print-trace
    --unwind=: | exception trace |
      return fail-block.call exception trace
    :
      return block.call
  unreachable
