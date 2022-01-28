// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.base64 as base64
import encoding.json as json

serialize object -> ByteArray:
  #primitive.serialization.serialize

deserialize bytes/ByteArray -> any:
  #primitive.serialization.deserialize

class A:
  field := ?
  constructor .field:

class B extends A:
  field2 := null

  constructor field:
    super field

confuse x -> any: return x

test [roundtrip]:
  expect_equals 499 (roundtrip.call "smi" 499)
  expect_equals -499 (roundtrip.call "neg_smi" -499)
  bits64 := 0x7FFF_FFFF_FFFF_FFFF
  expect_equals bits64 (roundtrip.call "int64" bits64)
  bits48 := 0xFFFF_FFFF_FFFF  // Smi on x64 bits, but not on x86.
  expect_equals bits48 (roundtrip.call "int48" bits48)
  // 'null', 'true', 'false' requires program-heap objects to roundtrip.call
  //   to the identical object.
  expect_equals null (roundtrip.call "null" null)
  expect_equals true (roundtrip.call "true" true)
  expect_equals false (roundtrip.call "false" false)

  a := A 499
  a2 := roundtrip.call "A" a
  expect a2 is A
  expect_equals 499 a.field
  b := B 42
  b.field2 = b
  b2 := roundtrip.call "B" b
  expect b2 is B
  expect_equals 42 b.field
  expect_equals b2 b2.field2

  x := 499
  y := 42
  fun := :: x + y
  if (confuse false): y++  // Make 'y' mutated.
  expect_equals 541 fun.call
  fun2 := roundtrip.call "lambda" fun
  expect_equals 541 fun2.call
  y++
  expect_equals 542 fun.call
  // The captured box is independent.
  expect_equals 541 fun2.call

  fun3 := :: y++
  fun_and_fun3 := roundtrip.call "list_funs" [fun, fun3]
  fun4 := fun_and_fun3[0]
  fun5 := fun_and_fun3[1]
  // Since the two functions were serialized together, their box is shared.
  expect_equals 542 fun4.call
  expect_equals 43 fun5.call
  expect_equals 543 fun4.call

roundtrip o: return deserialize (serialize o)

main args:
  should_serialize := not args.is_empty and args[0] == "--serialize"
  should_deserialize := not args.is_empty and args[0] == "--deserialize"

  if should_serialize:
    serialization_results := {:}
    test: |name o|
      serialized := serialize o
      serialization_results[name] = serialized
      deserialize serialized

    serialization_results.map --in_place: |key val| base64.encode val
    print (base64.encode (json.encode serialization_results))
  else if should_deserialize:
    encoded_base64_json := args[1]
    serialization_results := json.decode (base64.decode encoded_base64_json)
    test: |name o|
      actual := base64.encode (serialize o)
      given := serialization_results[name]
      expect_equals actual given
      deserialize (base64.decode given)
  else:
    test: |name o|
      deserialize (serialize o)
