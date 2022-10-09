// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *

test_atom object:
  expect_equals
      object
      tison.decode
          tison.encode object

test_array array:
  result := tison.decode
      tison.encode array
  expect_equals array.size result.size
  for i := 0; i < array.size; i++:
    expect_equals array[i] result[i]

test_map:
  map := Map
  map["1"] = "1"
  map["45"] = "45"
  result := tison.decode (tison.encode map)
  expect_equals result["1"] "1"
  expect_equals result["45"] "45"
  expect (not result.contains 2)

main:
  test_atom 12
  test_atom true
  test_atom false
  test_atom null
  test_atom ""
  test_atom "Fiskerdreng"
  test_array (Array_ 0)
  // No cycles, no reuse array.
  a := Array_ 4
  a[0] = 12
  a[1] = true
  a[2] = false
  a[3] = null
  test_array a
  // With strings.
  a = Array_ 4
  a[0] = "Fiskerdreng"
  a[1] = ""
  a[2] = "Fiskerdreng"
  a[3] = ""
  test_array a
  a = Array_ 1
  a[0] = "Fisk"
  test_array a
  c := 75
  test_map
  test_throwing_process_send
  test_tison_throwing

class Unserializable:

test_throwing_process_send:
  l := List 10: ByteArray_.external_ 100
  expect_throw "TOO_MANY_EXTERNALS": process_send_ 0 0 l
  // expect_throw "MESSAGE_NO_SUCH_RECEIVER": process_send_ 100000000 -10 #[]
  expect_null (process_send_ 100000000 -10 #[])
  l = []
  l.add l
  expect_throw "NESTING_TOO_DEEP": process_send_ 0 0 l
  l = [Unserializable]
  // We catch this, which means we don't get information about which class failed.
  // If we left it uncaught, the stack trace decoder would tell us.
  expect_throw "SERIALIZATION_FAILED": process_send_ 0 0 l

test_tison_throwing:
  l := []
  l.add l
  expect_throw "NESTING_TOO_DEEP": tison.encode l
  l = [Unserializable]
  // We catch this, which means we don't get information about which class failed.
  // If we left it uncaught, the stack trace decoder would tell us.
  expect_throw "SERIALIZATION_FAILED": tison.encode l
