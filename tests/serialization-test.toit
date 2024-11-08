// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *

test-atom object:
  expect-equals
      object
      tison.decode
          tison.encode object

test-array array:
  result := tison.decode
      tison.encode array
  expect-equals array.size result.size
  for i := 0; i < array.size; i++:
    expect-equals array[i] result[i]

test-map:
  map := Map
  map["1"] = "1"
  map["45"] = "45"
  result := tison.decode (tison.encode map)
  expect-equals result["1"] "1"
  expect-equals result["45"] "45"
  expect (not result.contains 2)

main:
  test-atom 12
  test-atom true
  test-atom false
  test-atom null
  test-atom ""
  test-atom "Fiskerdreng"
  test-array (Array_ 0)
  // No cycles, no reuse array.
  a := Array_ 4
  a[0] = 12
  a[1] = true
  a[2] = false
  a[3] = null
  test-array a
  // With strings.
  a = Array_ 4
  a[0] = "Fiskerdreng"
  a[1] = ""
  a[2] = "Fiskerdreng"
  a[3] = ""
  test-array a
  a = Array_ 1
  a[0] = "Fisk"
  test-array a
  c := 75
  test-map
  test-throwing-process-send
  test-tison-throwing

class Unserializable:

test-throwing-process-send:
  l := List 10: ByteArray.external 100
  expect-throw "TOO_MANY_EXTERNALS": process-send_ 0 0 l
  expect-not (process-send_ 100000000 -10 #[])
  l = []
  l.add l
  expect-throw "NESTING_TOO_DEEP": process-send_ 0 0 l
  l = [Unserializable]
  // We catch this, which means we don't get information about which class failed.
  // If we left it uncaught, the stack trace decoder would tell us.
  expect-throw "SERIALIZATION_FAILED": process-send_ 0 0 l
  // We had an issue where sending an object with an embedded map
  // would lead to a crash during deallocation -- but only if sent
  // to a non-existing process. Check that it now works.
  mappy := [ {"foo": "bar"}, #[1, 2, 3] ]
  expect-not (process-send_ 100000000 -10 mappy)

test-tison-throwing:
  l := []
  l.add l
  expect-throw "NESTING_TOO_DEEP": tison.encode l
  l = [Unserializable]
  // We catch this, which means we don't get information about which class failed.
  // If we left it uncaught, the stack trace decoder would tell us.
  expect-throw "SERIALIZATION_FAILED": tison.encode l
