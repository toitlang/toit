// Copyright (C) 2022 Toitware ApS. All rights reserved.

import rpc
import ..tools.rpc show RpcBroker
import expect
import monitor

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
  test_small_strings myself
  test_small_byte_arrays myself
  test_problematic myself
  test_closed_descriptor myself
  test_performance myself
  test_blocking myself broker

test_simple myself/int -> none:
  // Test simple types.
  test myself []
  test myself [7]
  test myself [7.3]
  test myself [1, 2]
  test myself ["hest"]
  test myself [ByteArray 10: it]

test_large_external myself/int -> none:
  expect.expect_equals 33199 (test_chain myself [ByteArray 33199: it])[0].size
  s := "hestfisk"
  15.repeat: s += s
  expect.expect_equals 262144 (test_chain myself [s])[0].size

  // Test that large enough byte arrays are neutered when sent.
  x := ByteArray 33199: it
  rpc.invoke myself PROCEDURE_ECHO [x]
  expect.expect_bytes_equal #[] x

test_second_procedure myself/int -> none:
  // Test second procedure.
  10.repeat:
    expect.expect_equals
        it * 2
        rpc.invoke myself PROCEDURE_MULTIPLY_BY_TWO [it]

test_small_strings myself/int -> none:
  collection := "abcdefghijklmn"
  s1 := ""
  s2 := ""
  (1 << 12).repeat:
    test myself [s1]
    test myself [s2]
    test myself [s1, s2]
    test myself [s2, s1]
    x := string.from_rune collection[it % collection.size]
    s1 = s1 + x
    s2 = x + s2

test_small_byte_arrays myself/int -> none:
  (1 << 12).repeat:
    b1 := ByteArray it: 7 - it
    b2 := ByteArray it: it + 9
    // Large enough byte arrays are neutered when sent, so make sure to copy
    // them before trying it out.
    expect.expect_list_equals [b1] (rpc.invoke myself PROCEDURE_ECHO [b1.copy])
    expect.expect_list_equals [b2] (rpc.invoke myself PROCEDURE_ECHO [b2.copy])
    expect.expect_list_equals [b1, b2] (rpc.invoke myself PROCEDURE_ECHO [b1.copy, b2.copy])
    expect.expect_list_equals [b2, b1] (rpc.invoke myself PROCEDURE_ECHO [b2.copy, b1.copy])

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

test_performance myself/int -> none:
  iterations := 100_000
  start := Time.monotonic_us
  iterations.repeat: rpc.invoke myself PROCEDURE_ECHO [it]
  end := Time.monotonic_us
  print_ "Time per rpc.invoke = $(%.1f (end - start).to_float/iterations) us"

test_blocking myself/int broker/RpcBroker -> none:
  // Check that we can still make progress even if all but one
  // processing task are blocked.
  test_blocking myself broker (RpcBroker.MAX_TASKS - 1):
    test_simple myself

  // Check that we get timeouts if we require too many tasks
  // to process at once.
  test_blocking myself broker (RpcBroker.MAX_TASKS):
    expect.expect_throw DEADLINE_EXCEEDED_ERROR:
      with_timeout --ms=200:
        test_simple myself

  // Check that the max request limits is honored.
  test_blocking myself broker (RpcBroker.MAX_TASKS):
    (RpcBroker.MAX_REQUESTS - RpcBroker.MAX_TASKS).repeat:
      task::
        test_simple myself
    expect.expect_throw "Cannot enqueue more requests":
      test_simple myself

test_blocking myself/int broker/RpcBroker tasks/int [test] -> none:
  name ::= 800
  latches ::= {:}
  broker.register_procedure name:: | args |
    index := args[0]
    latches[index].get

  // Create a number of tasks that all block.
  tasks.repeat:
    index ::= it
    latches[index] = monitor.Latch
    task:: expect.expect_equals index * 3 (rpc.invoke myself name [index])

  // Invoke the test.
  test.call

  // Let the tasks complete.
  tasks.repeat: latches[it].set it * 3


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
