// Copyright (C) 2022 Toitware ApS. All rights reserved.

import rpc
import ..tools.rpc show RpcBroker
import expect

PROCEDURE_MULTIPLY_BY_TWO/int ::= 500
PROCEDURE_ECHO/int            ::= 501

main:
  myself := current_process_
  broker := RpcBroker
  broker.install

  broker.register_procedure PROCEDURE_ECHO:: | args |
    args

  broker.register_procedure PROCEDURE_MULTIPLY_BY_TWO:: | args |
    args[0] * 2

  // Test simple types.
  test myself []
  test myself [7]
  test myself [7.3]
  test myself [1, 2]
  test myself ["hest"]
  test myself [ByteArray 10: it]

  // Test large external types.
  test_large_external myself

  // Test second procedure.
  10.repeat:
    expect.expect_equals
        it * 2
        rpc.invoke myself PROCEDURE_MULTIPLY_BY_TWO [it]

  iterations := 100_000
  start := Time.monotonic_us
  iterations.repeat: rpc.invoke myself PROCEDURE_ECHO [it]
  end := Time.monotonic_us
  print_ "Time per rpc.invoke = $(%.1f (end - start).to_float/iterations) us"

  // Check for unhandled types of data.
  test_illegal myself [MyClass]
  test_illegal myself [ #[1, 2, 3, 4] ]  // TODO(kasper): This should be handled.

  // Check for cyclic data structure.
  cyclic := []
  cyclic.add cyclic
  test_illegal myself cyclic

test myself/int arguments/List:
  expect.expect_list_equals arguments
      rpc.invoke myself PROCEDURE_ECHO arguments

test_illegal myself/int arguments/List:
  expect.expect_throw "WRONG_OBJECT_TYPE": rpc.invoke myself PROCEDURE_ECHO arguments

test_large_external myself/int:
  expect.expect_equals 17281 (test_chain myself [ByteArray 17281: it])[0].size
  s := "hestfisk"
  15.repeat: s += s
  expect.expect_equals 262144 (test_chain myself [s])[0].size

test_chain myself/int arguments/List -> List:
  1024.repeat: arguments = rpc.invoke myself PROCEDURE_ECHO arguments
  return arguments

class MyClass:
  // Empty.
