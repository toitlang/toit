// Copyright (C) 2022 Toitware ApS. All rights reserved.

import rpc
import ..tools.rpc show RpcBroker
import expect

PROCEDURE_MULTIPLY_BY_TWO/int ::= 500
PROCEDURE_ECHO/int            ::= 501
PROCEDURE_DESCRIPTOR/int      ::= 502

class TestBroker extends RpcBroker:
  // Nothing yet.

main:
  myself := current_process_
  broker := TestBroker
  broker.install

  broker.register_procedure PROCEDURE_ECHO:: | args |
    args
  broker.register_procedure PROCEDURE_MULTIPLY_BY_TWO:: | args |
    args[0] * 2
  broker.register_descriptor_procedure PROCEDURE_DESCRIPTOR:: | descriptor args |
    args

  test_simple myself
  test_large_external myself
  test_second_procedure myself
  test_problematic myself
  test_closed_descriptor myself
  test_performance myself

test_simple myself/int -> none:
  // Test simple types.
  test myself []
  test myself [7]
  test myself [7.3]
  test myself [1, 2]
  test myself ["hest"]
  test myself [ByteArray 10: it]

test_large_external myself/int -> none:
  expect.expect_equals 17281 (test_chain myself [ByteArray 17281: it])[0].size
  s := "hestfisk"
  15.repeat: s += s
  expect.expect_equals 262144 (test_chain myself [s])[0].size

test_second_procedure myself/int  -> none:
  // Test second procedure.
  10.repeat:
    expect.expect_equals
        it * 2
        rpc.invoke myself PROCEDURE_MULTIPLY_BY_TWO [it]

test_problematic myself/int -> none:
  // Check for unhandled types of data.
  test_illegal myself [MyClass]
  test_illegal myself [ #[1, 2, 3, 4] ]  // TODO(kasper): This should be handled.

  // Check for cyclic data structure.
  cyclic := []
  cyclic.add cyclic
  test_illegal myself cyclic

test_closed_descriptor myself/int -> none:
  expect.expect_throw "Missing call context": rpc.invoke myself PROCEDURE_DESCRIPTOR []
  expect.expect_throw "Closed descriptor 42": rpc.invoke myself PROCEDURE_DESCRIPTOR [42]
  expect.expect_throw "Closed descriptor fang": rpc.invoke myself PROCEDURE_DESCRIPTOR ["fang"]

test_performance myself/int:
  iterations := 100_000
  start := Time.monotonic_us
  iterations.repeat: rpc.invoke myself PROCEDURE_ECHO [it]
  end := Time.monotonic_us
  print_ "Time per rpc.invoke = $(%.1f (end - start).to_float/iterations) us"

// ----------------------------------------------------------------------------

test myself/int arguments/List:
  expect.expect_list_equals arguments
      rpc.invoke myself PROCEDURE_ECHO arguments

test_illegal myself/int arguments/List:
  expect.expect_throw "WRONG_OBJECT_TYPE": rpc.invoke myself PROCEDURE_ECHO arguments


test_chain myself/int arguments/List -> List:
  1024.repeat: arguments = rpc.invoke myself PROCEDURE_ECHO arguments
  return arguments

class MyClass:
  // Empty.
