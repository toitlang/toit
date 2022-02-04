// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import rpc
import rpc.broker show RpcBroker RpcRequest_ RpcRequestQueue_
import expect
import monitor

PROCEDURE_ECHO/int            ::= 500
PROCEDURE_ECHO_WRAPPED/int    ::= 501
PROCEDURE_MULTIPLY_BY_TWO/int ::= 502

class TestBroker extends RpcBroker:
  terminated_ := {}

  is_valid_sender gid/int pid/int -> bool:
    return not terminated_.contains pid

  reset_terminated -> none:
    terminated_.clear

  terminate pid/int -> none:
    terminated_.add pid
    cancel_requests pid

main:
  myself := current_process_
  broker := TestBroker
  broker.install

  broker.register_procedure PROCEDURE_ECHO:: | args |
    args
  broker.register_procedure PROCEDURE_ECHO_WRAPPED:: | args |
    MySerializable args
  broker.register_procedure PROCEDURE_MULTIPLY_BY_TWO:: | args |
    args[0] * 2

  test_simple myself
  test_large_external myself
  test_second_procedure myself
  test_serializable myself
  test_small_strings myself
  test_small_byte_arrays myself
  test_problematic myself
  test_performance myself
  test_blocking myself broker

  test_request_queue_cancel myself
  test_timeouts myself broker --cancel
  test_timeouts myself broker --no-cancel
  test_ensure_processing_task myself broker
  test_terminate myself broker

test_simple myself/int -> none:
  // Test simple types.
  test myself 3
  test myself 3.9
  test myself null
  test myself true
  test myself false
  test myself "fisk"

  // Test simple lists.
  test myself []
  test myself [7]
  test myself [7.3]
  test myself [1, 2]
  test myself ["hest"]
  test myself [ByteArray 10: it]

  // Test copy-on-write byte arrays.
  test myself #[1, 2, 3, 4]
  test myself [#[3, 4, 5]]
  big_cow := #[
       0,  1,  2,  3,  4,  5,  6,  7,  8,  9,
      10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
      20, 21, 22, 23]
  test myself big_cow

  // Test modified copy-on-write arrays.
  modified_cow := #[1, 2, 3]
  test myself modified_cow
  modified_cow[1] = 9
  test myself modified_cow
  modified_cow[2] = 19
  test myself modified_cow

  // Test byte array slices.
  test myself (ByteArray 10: it)[3..4]
  test myself [(ByteArray 10: it)[3..5]]
  test myself #[1, 2, 3, 4][1..2]
  test myself [#[1, 2, 3, 4][0..1]]
  test myself [(ByteArray 100: it)[7..51]]
  test myself big_cow[0..17]
  test myself [big_cow[1..18]]

  // Testing string slices.
  test myself "hestfisk"[1..3]
  test myself ["hestfisk"[2..5]]
  test myself ("hestfisk"*8)[4..32]
  test myself [("hestfisk"*8)[5..37]]

test_large_external myself/int -> none:
  expect.expect_equals 33199 (test_chain myself [ByteArray 33199: it])[0].size
  s := "hestfisk"
  15.repeat: s += s
  expect.expect_equals 262144 (test_chain myself [s])[0].size

  // Test that large enough byte arrays are neutered when sent.
  x := ByteArray 33199: it
  rpc.invoke myself PROCEDURE_ECHO [x]
  expect.expect x is ByteArray
  expect.expect x.is_empty
  expect.expect_bytes_equal #[] x

test_second_procedure myself/int -> none:
  // Test second procedure.
  10.repeat:
    expect.expect_equals
        it * 2
        rpc.invoke myself PROCEDURE_MULTIPLY_BY_TWO [it]

test_serializable myself/int -> none:
  test myself (MySerializable 4)
  test myself (MySerializable 4.3)
  test myself (MySerializable [1, 2, 3])

class MySerializable implements rpc.RpcSerializable:
  wrapped/any
  constructor .wrapped:
  serialize_for_rpc -> any: return wrapped

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
  test_illegal myself [MySerializable 4]

  // Check for cyclic data structure.
  cyclic := []
  cyclic.add cyclic
  test_illegal myself cyclic

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

  // Unregister procedure and make sure it's gone.
  broker.unregister_procedure name
  expect.expect_throw "No such procedure registered: 800": rpc.invoke myself name []

cancel queue/RpcRequestQueue_ pid/int id/int -> int:
  result/int := 0
  queue.cancel: | request/RpcRequest_ |
    match/bool := request.pid == pid and request.id == id
    if match: result++
    match
  return result

test_request_queue_cancel myself/int -> none:
  queue := RpcRequestQueue_ 0
  expect.expect_equals 0 queue.unprocessed_
  expect.expect_null queue.first_
  expect.expect_null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 it null:: unreachable)
  expect.expect_equals 10 queue.unprocessed_
  10.repeat:
    expect.expect_equals (10 - it) queue.unprocessed_
    expect.expect_equals 0 (cancel queue (myself + 1) it)  // Try canceling request for other pid.
    expect.expect_equals (10 - it) queue.unprocessed_
    expect.expect_equals 1 (cancel queue myself it)
  expect.expect_equals 0 queue.unprocessed_
  expect.expect_null queue.first_
  expect.expect_null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 it null:: unreachable)
  expect.expect_equals 10 queue.unprocessed_
  10.repeat:
    expect.expect_equals 1 (cancel queue myself (10 - it - 1))
  expect.expect_equals 0 queue.unprocessed_
  expect.expect_null queue.first_
  expect.expect_null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 it null:: unreachable)
  expect.expect_equals 10 queue.unprocessed_
  expect.expect_equals 1 (cancel queue myself 5)
  expect.expect_equals 9 queue.unprocessed_
  expect.expect_equals 0 (cancel queue myself 5)
  expect.expect_equals 9 queue.unprocessed_

  expect.expect_equals 1 (cancel queue myself 7)
  expect.expect_equals 8 queue.unprocessed_
  expect.expect_equals 1 (cancel queue myself 3)
  expect.expect_equals 7 queue.unprocessed_

  10.repeat: cancel queue myself it
  expect.expect_equals 0 queue.unprocessed_
  expect.expect_null queue.first_
  expect.expect_null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 42 null:: unreachable)
  expect.expect_equals 10 queue.unprocessed_
  expect.expect_equals 10 (cancel queue myself 42)
  expect.expect_equals 0 queue.unprocessed_
  expect.expect_null queue.first_
  expect.expect_null queue.last_

test_timeouts myself/int broker/RpcBroker --cancel/bool -> none:
  name ::= 801
  latches := {:}
  broker.register_procedure name:: | index |
    try:
      // If a task starts processing this request, we tell the
      // caller to wait for the result.
      latches[index] = monitor.Latch
      // Block until canceled.
      (monitor.Latch).get
    finally:
      if task.is_canceled:
        latches[index].set "Canceled: $index"

  // Use 'with_timeout' to trigger the timeout.
  timeout_based/Lambda := :: | index |
    expect.expect_throw DEADLINE_EXCEEDED_ERROR: with_timeout --ms=10:
      latches[index] = monitor.Latch
      latches[index].set "Unprocessed: $index"
      rpc.invoke myself name index

  // Use 'sleep' and 'Task.cancel' to trigger the timeout.
  sleep_cancel_based/Lambda ::= :: | index |
    join := monitor.Latch
    subtask := task::
      latches[index] = monitor.Latch
      latches[index].set "Unprocessed: $index"
      try:
        rpc.invoke myself name index
      finally: | is_exception exception |
        expect.expect task.is_canceled
        join.set task
    sleep --ms=10
    subtask.cancel
    expect.expect_identical subtask join.get

  unprocessed := 0
  canceled := 0
  done ::= monitor.Semaphore

  test := :: | index |
    if cancel: sleep_cancel_based.call index
    else: timeout_based.call index
    result := null
    with_timeout --ms=100: result = latches[index].get
    latches.remove index
    if result == "Unprocessed: $index":
      unprocessed++
    else if result == "Canceled: $index":
      canceled++
    else:
      expect.expect false --message="Unexpected result <$result>"
    done.up

  unprocessed = canceled = 0
  RpcBroker.MAX_REQUESTS.repeat: | index |
    test.call index
  RpcBroker.MAX_REQUESTS.repeat:
    done.down
  expect.expect_equals 0 unprocessed
  expect.expect_equals RpcBroker.MAX_REQUESTS canceled

  unprocessed = canceled = 0
  RpcBroker.MAX_TASKS.repeat: | index |
    task:: test.call index
  RpcBroker.MAX_TASKS.repeat:
    done.down
  expect.expect_equals 0 unprocessed
  expect.expect_equals RpcBroker.MAX_TASKS canceled

  unprocessed = canceled = 0
  RpcBroker.MAX_REQUESTS.repeat: | index |
    task:: test.call index
  RpcBroker.MAX_REQUESTS.repeat:
    done.down
  // It is possible that a canceled processing tasks grabs hold of an
  // unprocessed request and starts processing while we are canceling
  // other requests.
  expect.expect_equals RpcBroker.MAX_REQUESTS (unprocessed + canceled)
  expect.expect canceled >= RpcBroker.MAX_TASKS

  // Unregister procedure and make sure it's gone.
  broker.unregister_procedure name
  expect.expect_throw "No such procedure registered: $name": rpc.invoke myself name []

test_ensure_processing_task myself/int broker/RpcBroker -> none:
  name ::= 802
  broker.register_procedure name:: | index |
    // Block until canceled.
    (monitor.Latch).get

  // Block all processing tasks one-by-one, but cancel them after a little while.
  RpcBroker.MAX_TASKS.repeat:
    expect.expect_throw DEADLINE_EXCEEDED_ERROR:
      with_timeout --ms=50: rpc.invoke myself name []
  with_timeout --ms=200: test myself 42

  // Block all processing tasks at once, but cancel them after a little while.
  done := monitor.Semaphore
  RpcBroker.MAX_TASKS.repeat:
    task::
      expect.expect_throw DEADLINE_EXCEEDED_ERROR:
        with_timeout --ms=50: rpc.invoke myself name []
      done.up
  with_timeout --ms=200: test myself 87
  RpcBroker.MAX_TASKS.repeat: done.down

  // Unregister procedure and make sure it's gone.
  broker.unregister_procedure name
  expect.expect_throw "No such procedure registered: $name": rpc.invoke myself name []

test_terminate myself/int broker/TestBroker -> none:
  test_terminate myself broker 1
  test_terminate myself broker RpcBroker.MAX_TASKS
  test_terminate myself broker RpcBroker.MAX_REQUESTS

test_terminate myself/int broker/TestBroker n/int -> none:
  name ::= 803
  broker.register_procedure name:: | index |
    // Block until canceled.
    (monitor.Latch).get

  // Check that we start under the expected conditions.
  expect.expect_equals 0 broker.queue_.unprocessed_
  expect.expect_null broker.queue_.first_
  expect.expect_null broker.queue_.last_

  // Check that terminating a process and cancelling requests take care
  // of both requests that are enqueued and requests that are being
  // processed.
  broker.reset_terminated
  done := monitor.Semaphore
  n.repeat: task::
    try:
      exception := catch: with_timeout --ms=200: rpc.invoke myself name []
      expect.expect (task.is_canceled or exception == DEADLINE_EXCEEDED_ERROR)
    finally:
      done.up
  sleep --ms=20
  expect.expect_equals n broker.queue_.unprocessed_
  broker.terminate myself
  sleep --ms=20
  n.repeat: done.down

  // Check that we get back to the starting conditions.
  expect.expect_equals 0 broker.queue_.unprocessed_
  expect.expect_null broker.queue_.first_
  expect.expect_null broker.queue_.last_

  // If a task from a dead process has already sent messages to the broker,
  // they are simply discarded.
  finished := monitor.Latch
  dead := task::
    expect.expect_throw DEADLINE_EXCEEDED_ERROR:
      with_timeout --ms=100: test myself 99
    finished.set task
  expect.expect_identical dead finished.get

  // If we revive the process, messages are accepted again.
  broker.reset_terminated
  test myself 87

  // Unregister procedure and make sure it's gone.
  broker.unregister_procedure name
  expect.expect_throw "No such procedure registered: $name": rpc.invoke myself name []

// ----------------------------------------------------------------------------

test myself/int arguments/any:
  expected/any := arguments
  actual/any := ?
  if arguments is MySerializable:
    actual = rpc.invoke myself PROCEDURE_ECHO_WRAPPED arguments
    expected = arguments.serialize_for_rpc
  else:
    actual = rpc.invoke myself PROCEDURE_ECHO arguments
  if arguments is List:
    expect.expect_list_equals expected actual
  else:
    expect.expect_equals expected actual

test_illegal myself/int arguments/any:
  expect.expect_throw "WRONG_OBJECT_TYPE": rpc.invoke myself PROCEDURE_ECHO arguments

test_chain myself/int arguments/any -> List:
  1024.repeat: arguments = rpc.invoke myself PROCEDURE_ECHO arguments
  return arguments

class MyClass:
  // Empty.
