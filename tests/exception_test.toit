// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect_ name [code]:
  expect_equals
    name
    catch code

expect_out_of_bounds [code]:
  expect_ "OUT_OF_BOUNDS" code

expect_illegal_utf_8 [code]:
  expect_ "ILLEGAL_UTF_8" code

expect_out_of_range [code]:
  expect_ "OUT_OF_RANGE" code

expect_wrong_type [code]:
  exception_name := catch code
  expect
      exception_name == "WRONG_OBJECT_TYPE" or exception_name == "AS_CHECK_FAILED"

expect_wrong_array_index_type [code]:
  exception_name := catch code
  expect
      exception_name == "WRONG_OBJECT_TYPE" or exception_name == "AS_CHECK_FAILED"

expect_lookup_failed [code]:
  expect_ "LOOKUP_FAILED" code

expect_code_failed [code]:
  expect_ "CODE_INVOCATION_FAILED" code

expect_stack_overflow [code]:
  expect_ "STACK_OVERFLOW" code

expect_allocation_size_exceeded [code]:
  expect_ "ALLOCATION_SIZE_EXCEEDED" code

expect_negative_argument [code]:
  expect_ "NEGATIVE_ARGUMENT" code

confuse x -> any: return x

class TheOther:

main:
  test_framework
  test_array_exceptions
  test_list_exceptions
  test_integer_exceptions
  test_float_exceptions
  test_string_exceptions
  test_lookup_exceptions
  test_code_exceptions
  test_stack_overflow_exception
  test_allocation_size_exceeded

test_framework:
  expect_lookup_failed:     throw "LOOKUP_FAILED"
  expect_code_failed:       throw "CODE_INVOCATION_FAILED"
  expect_wrong_type:        throw "WRONG_OBJECT_TYPE"
  expect_out_of_bounds:     throw "OUT_OF_BOUNDS"
  expect_illegal_utf_8:     throw "ILLEGAL_UTF_8"
  expect_out_of_range:      throw "OUT_OF_RANGE"
  expect_stack_overflow:    throw "STACK_OVERFLOW"
  expect_negative_argument: throw "NEGATIVE_ARGUMENT"

test_lookup_exceptions:
  expect_lookup_failed: (confuse 12).fiskerdreng
  expect_lookup_failed: (confuse TheOther).at 4

invoke_lambda f:
  f.call

invoke_lambda x f:
  f.call x

invoke_block [b]:
  b.call

invoke_block x [b]:
  b.call x

test_code_exceptions:
  expect_code_failed: invoke_lambda:: it
  expect_code_failed: invoke_lambda 0:: |a b| 0
  expect_code_failed: invoke_lambda 0:: |a b c| 0
  expect_code_failed: invoke_block: it
  expect_code_failed: invoke_block 0: |a b| 0
  expect_code_failed: invoke_block 0: |a b c| 0
  expect_code_failed: [12].do: | a b | 0
  expect_code_failed: [12].do: | a b c | 0

test_list_exceptions:
  expect_out_of_bounds: List -1
  expect_wrong_array_index_type: List (confuse "fisk")

  expect_out_of_bounds: [].remove_last

  list := []
  1025.repeat: list.add null // Large array
  expect_out_of_bounds: list[1026]
  expect_out_of_bounds: list[1026] = 0
  expect_out_of_bounds: list[1025]
  expect_out_of_bounds: list[1025] = 0
  expect_out_of_bounds: list[-1]
  expect_out_of_bounds: list[-1] = 0
  expect_wrong_type: list[confuse null]
  expect_wrong_type: list[confuse list]
  expect_wrong_type: list[confuse "fisk"]

test_array_exceptions:
  expect_out_of_bounds: Array_ -1
  expect_wrong_array_index_type: Array_ (confuse "fisk")

  array := Array_ 1
  expect_out_of_bounds: array[2]
  expect_out_of_bounds: array[2] = 0
  expect_out_of_bounds: array[1]
  expect_out_of_bounds: array[1] = 0
  expect_out_of_bounds: array[-1]
  expect_out_of_bounds: array[-1] = 0
  expect_wrong_type: array[confuse null]
  expect_wrong_type: array[confuse array]
  expect_wrong_type: array[confuse "fisk"]

  array = Array_ 1025  // Large array
  expect_out_of_bounds: array[1026]
  expect_out_of_bounds: array[1026] = 0
  expect_out_of_bounds: array[1025]
  expect_out_of_bounds: array[1025] = 0
  expect_out_of_bounds: array[-1]
  expect_out_of_bounds: array[-1] = 0
  expect_wrong_array_index_type: array[confuse null]
  expect_wrong_array_index_type: array[confuse array]
  expect_wrong_array_index_type: array[confuse "fisk"]

test_integer_exceptions:
  expect_lookup_failed: 23 < (confuse "fisk")
  expect_lookup_failed: 23 <= (confuse [1])
  expect_lookup_failed: 23 > (confuse {})
  expect_lookup_failed: 23 >= (confuse {:})
  expect_lookup_failed: 23 + (confuse "fisk")
  expect_lookup_failed: 23 - (confuse [1])
  expect_lookup_failed: 23 / (confuse {})
  expect_lookup_failed: 23 * (confuse {:})
  expect_lookup_failed: 23 % (confuse true)
  expect_wrong_type: 23 >> (confuse 12.12)
  expect_wrong_type: 23 << (confuse 12.12)
  expect_negative_argument: 12 << -1
  expect_negative_argument: 12 >> -1
  expect_negative_argument: 12 << -1
  expect_negative_argument: 12 >> -1

test_float_exceptions:
  expect_lookup_failed: 23.23 < "fisk"
  expect_lookup_failed: 23.23 <= [1]
  expect_lookup_failed: 23.23 > {}
  expect_lookup_failed: 23.23 >= {:}
  expect_lookup_failed: 23.23 + "fisk"
  expect_lookup_failed: 23.23 - [1]
  expect_lookup_failed: 23.23 / {}
  expect_lookup_failed: 23.23 * {:}

test_string_exceptions:
  a := "Fiskerdreng"
  expect_wrong_type: a[confuse a]
  expect_out_of_bounds: a[-1]
  expect_out_of_bounds: a[a.size]

recurse a b c:
  recurse a+1 b+2 c+3

test_stack_overflow_exception:
  expect_stack_overflow: recurse 1 2 3

test_allocation_size_exceeded:
  // Enable when read_entire file problem has been solved.
  // expect_allocation_size_exceeded: ByteArray 1200000

