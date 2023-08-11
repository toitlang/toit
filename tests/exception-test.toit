// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect_ name [code]:
  expect-equals
    name
    catch code

expect-out-of-bounds [code]:
  expect_ "OUT_OF_BOUNDS" code

expect-illegal-utf-8 [code]:
  expect_ "ILLEGAL_UTF_8" code

expect-out-of-range [code]:
  expect_ "OUT_OF_RANGE" code

expect-wrong-type [code]:
  exception-name := catch code
  expect
      exception-name == "WRONG_OBJECT_TYPE" or exception-name == "AS_CHECK_FAILED"

expect-wrong-array-index-type [code]:
  exception-name := catch code
  expect
      exception-name == "WRONG_OBJECT_TYPE" or exception-name == "AS_CHECK_FAILED"

expect-lookup-failed [code]:
  expect_ "LOOKUP_FAILED" code

expect-code-failed [code]:
  expect_ "CODE_INVOCATION_FAILED" code

expect-stack-overflow [code]:
  expect_ "STACK_OVERFLOW" code

expect-allocation-size-exceeded [code]:
  expect_ "ALLOCATION_SIZE_EXCEEDED" code

expect-negative-argument [code]:
  expect_ "NEGATIVE_ARGUMENT" code

confuse x -> any: return x

class TheOther:

main:
  test-framework
  test-array-exceptions
  test-list-exceptions
  test-integer-exceptions
  test-float-exceptions
  test-string-exceptions
  test-lookup-exceptions
  test-code-exceptions
  test-stack-overflow-exception

test-framework:
  expect-lookup-failed:     throw "LOOKUP_FAILED"
  expect-code-failed:       throw "CODE_INVOCATION_FAILED"
  expect-wrong-type:        throw "WRONG_OBJECT_TYPE"
  expect-out-of-bounds:     throw "OUT_OF_BOUNDS"
  expect-illegal-utf-8:     throw "ILLEGAL_UTF_8"
  expect-out-of-range:      throw "OUT_OF_RANGE"
  expect-stack-overflow:    throw "STACK_OVERFLOW"
  expect-negative-argument: throw "NEGATIVE_ARGUMENT"

test-lookup-exceptions:
  expect-lookup-failed: (confuse 12).fiskerdreng
  expect-lookup-failed: (confuse TheOther).at 4

invoke-lambda f:
  f.call

invoke-lambda x f:
  f.call x

invoke-block [b]:
  b.call

invoke-block x [b]:
  b.call x

test-code-exceptions:
  expect-code-failed: invoke-lambda:: it
  expect-code-failed: invoke-lambda 0:: |a b| 0
  expect-code-failed: invoke-lambda 0:: |a b c| 0
  expect-code-failed: invoke-block: it
  expect-code-failed: invoke-block 0: |a b| 0
  expect-code-failed: invoke-block 0: |a b c| 0
  expect-code-failed: [12].do: | a b | 0
  expect-code-failed: [12].do: | a b c | 0

test-list-exceptions:
  expect-out-of-bounds: List -1
  expect-wrong-array-index-type: List (confuse "fisk")

  expect-out-of-bounds: [].remove-last

  list := []
  1025.repeat: list.add null // Large array
  expect-out-of-bounds: list[1026]
  expect-out-of-bounds: list[1026] = 0
  expect-out-of-bounds: list[1025]
  expect-out-of-bounds: list[1025] = 0
  expect-out-of-bounds: list[-1]
  expect-out-of-bounds: list[-1] = 0
  expect-wrong-type: list[confuse null]
  expect-wrong-type: list[confuse list]
  expect-wrong-type: list[confuse "fisk"]

test-array-exceptions:
  expect-out-of-bounds: Array_ -1
  expect-wrong-array-index-type: Array_ (confuse "fisk")

  array := Array_ 1
  expect-out-of-bounds: array[2]
  expect-out-of-bounds: array[2] = 0
  expect-out-of-bounds: array[1]
  expect-out-of-bounds: array[1] = 0
  expect-out-of-bounds: array[-1]
  expect-out-of-bounds: array[-1] = 0
  expect-wrong-type: array[confuse null]
  expect-wrong-type: array[confuse array]
  expect-wrong-type: array[confuse "fisk"]

  array = Array_ 1025  // Large array
  expect-out-of-bounds: array[1026]
  expect-out-of-bounds: array[1026] = 0
  expect-out-of-bounds: array[1025]
  expect-out-of-bounds: array[1025] = 0
  expect-out-of-bounds: array[-1]
  expect-out-of-bounds: array[-1] = 0
  expect-wrong-array-index-type: array[confuse null]
  expect-wrong-array-index-type: array[confuse array]
  expect-wrong-array-index-type: array[confuse "fisk"]

test-integer-exceptions:
  expect-lookup-failed: 23 < (confuse "fisk")
  expect-lookup-failed: 23 <= (confuse [1])
  expect-lookup-failed: 23 > (confuse {})
  expect-lookup-failed: 23 >= (confuse {:})
  expect-lookup-failed: 23 + (confuse "fisk")
  expect-lookup-failed: 23 - (confuse [1])
  expect-lookup-failed: 23 / (confuse {})
  expect-lookup-failed: 23 * (confuse {:})
  expect-lookup-failed: 23 % (confuse true)
  expect-wrong-type: 23 >> (confuse 12.12)
  expect-wrong-type: 23 << (confuse 12.12)
  expect-negative-argument: 12 << -1
  expect-negative-argument: 12 >> -1
  expect-negative-argument: 12 << -1
  expect-negative-argument: 12 >> -1

test-float-exceptions:
  expect-lookup-failed: 23.23 < "fisk"
  expect-lookup-failed: 23.23 <= [1]
  expect-lookup-failed: 23.23 > {}
  expect-lookup-failed: 23.23 >= {:}
  expect-lookup-failed: 23.23 + "fisk"
  expect-lookup-failed: 23.23 - [1]
  expect-lookup-failed: 23.23 / {}
  expect-lookup-failed: 23.23 * {:}

test-string-exceptions:
  a := "Fiskerdreng"
  expect-wrong-type: a[confuse a]
  expect-out-of-bounds: a[-1]
  expect-out-of-bounds: a[a.size]

recurse a b c:
  recurse a+1 b+2 c+3

test-stack-overflow-exception:
  expect-stack-overflow: recurse 1 2 3
