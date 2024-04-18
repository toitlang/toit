// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import rpc
import rpc.broker show RpcBroker RpcRequest_ RpcRequestQueue_
import expect
import monitor

PROCEDURE-ECHO/int            ::= 500
PROCEDURE-ECHO-WRAPPED/int    ::= 501
PROCEDURE-MULTIPLY-BY-TWO/int ::= 502

class TestBroker extends RpcBroker:
  terminated_ := {}

  accept gid/int pid/int -> bool:
    return not terminated_.contains pid

  reset-terminated -> none:
    terminated_.clear

  terminate pid/int -> none:
    terminated_.add pid
    cancel-requests pid

main:
  myself := Process.current.id
  broker := TestBroker
  broker.install

  broker.register-procedure PROCEDURE-ECHO:: | args |
    args
  broker.register-procedure PROCEDURE-ECHO-WRAPPED:: | args |
    MySerializable args
  broker.register-procedure PROCEDURE-MULTIPLY-BY-TWO:: | args |
    args[0] * 2

  expect.expect-throw "NO_SUCH_PROCESS":
    rpc.invoke 1919 PROCEDURE-ECHO [42]

  test-simple myself
  test-large-external myself
  test-second-procedure myself
  test-serializable myself
  test-small-strings myself
  test-small-byte-arrays myself
  test-problematic myself
  test-performance myself
  test-blocking myself broker
  test-sequential myself broker
  test-map myself

  test-request-queue-cancel myself
  test-timeouts myself broker --cancel
  test-timeouts myself broker --no-cancel
  test-ensure-processing-task myself broker
  test-terminate myself broker

test-simple myself/int -> none:
  // Test simple types.
  test myself 3
  test myself 3.9
  test myself null
  test myself true
  test myself false
  test myself "fisk"
  test myself 0xb00ffeed

  // Test simple lists.
  test myself []
  test myself [7]
  test myself [7.3]
  test myself [1, 2]
  test myself ["hest"]
  test myself [ByteArray 10: it]
  test myself [0, 1, 2, 0xb00ffeed, 3, 4]

  // Test copy-on-write byte arrays.
  test myself #[1, 2, 3, 4]
  test myself [#[3, 4, 5]]
  big-cow := #[
       0,  1,  2,  3,  4,  5,  6,  7,  8,  9,
      10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
      20, 21, 22, 23]
  test myself big-cow

  // Test modified copy-on-write arrays.
  modified-cow := #[1, 2, 3]
  test myself modified-cow
  modified-cow[1] = 9
  test myself modified-cow
  modified-cow[2] = 19
  test myself modified-cow

  // Test byte array slices.
  test myself (ByteArray 10: it)[3..4]
  test myself [(ByteArray 10: it)[3..5]]
  test myself #[1, 2, 3, 4][1..2]
  test myself [#[1, 2, 3, 4][0..1]]
  test myself [(ByteArray 100: it)[7..51]]
  test myself big-cow[0..17]
  test myself [big-cow[1..18]]

  // Testing string slices.
  test myself "hestfisk"[1..3]
  test myself ["hestfisk"[2..5]]
  test myself ("hestfisk"*8)[4..32]
  test myself [("hestfisk"*8)[5..37]]

test-large-external myself/int -> none:
  expect.expect-equals 33199 (test-chain myself [ByteArray 33199: it])[0].size
  s := "hestfisk"
  15.repeat: s += s
  expect.expect-equals 262144 (test-chain myself [s])[0].size

  // Test that large enough byte arrays are neutered when sent.
  x := ByteArray 33199: it
  rpc.invoke myself PROCEDURE-ECHO [x]
  expect.expect x is ByteArray
  expect.expect x.is-empty
  expect.expect-bytes-equal #[] x

test-second-procedure myself/int -> none:
  // Test second procedure.
  10.repeat:
    expect.expect-equals
        it * 2
        rpc.invoke myself PROCEDURE-MULTIPLY-BY-TWO [it]

test-serializable myself/int -> none:
  test myself (MySerializable 4)
  test myself (MySerializable 4.3)
  test myself (MySerializable [1, 2, 3])

class MySerializable implements rpc.RpcSerializable:
  wrapped/any
  constructor .wrapped:
  serialize-for-rpc -> any: return wrapped

test-small-strings myself/int -> none:
  collection := "abcdefghijklmn"
  s1 := ""
  s2 := ""
  (1 << 12).repeat:
    test myself [s1]
    test myself [s2]
    test myself [s1, s2]
    test myself [s2, s1]
    x := string.from-rune collection[it % collection.size]
    s1 = s1 + x
    s2 = x + s2

test-small-byte-arrays myself/int -> none:
  (1 << 12).repeat:
    b1 := ByteArray it: 7 - it
    b2 := ByteArray it: it + 9
    // Large enough byte arrays are neutered when sent, so make sure to copy
    // them before trying it out.
    expect.expect-list-equals [b1] (rpc.invoke myself PROCEDURE-ECHO [b1.copy])
    expect.expect-list-equals [b2] (rpc.invoke myself PROCEDURE-ECHO [b2.copy])
    expect.expect-list-equals [b1, b2] (rpc.invoke myself PROCEDURE-ECHO [b1.copy, b2.copy])
    expect.expect-list-equals [b2, b1] (rpc.invoke myself PROCEDURE-ECHO [b2.copy, b1.copy])

test-problematic myself/int -> none:
  // Check for unhandled types of data.
  test-serialization-failed myself [MyClass]
  test-serialization-failed myself [MySerializable 4]

  // Check for cyclic data structure.
  cyclic := []
  cyclic.add cyclic
  test-cyclic myself cyclic

test-performance myself/int -> none:
  iterations := 100_000
  start := Time.monotonic-us
  iterations.repeat: rpc.invoke myself PROCEDURE-ECHO [it]
  end := Time.monotonic-us
  print_ "Time per rpc.invoke = $(%.1f (end - start).to-float/iterations) us"

test-blocking myself/int broker/RpcBroker -> none:
  // Check that we can still make progress even if all but one
  // processing task are blocked.
  test-blocking myself broker (RpcBroker.MAX-TASKS - 1):
    test-simple myself

  // Check that we get timeouts if we require too many tasks
  // to process at once.
  test-blocking myself broker (RpcBroker.MAX-TASKS):
    expect.expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=200:
        test-simple myself

  // Check that the max request limit is honored.
  test-blocking myself broker (RpcBroker.MAX-TASKS):
    expected-exception ::= "Cannot enqueue more requests"
    capacity ::= RpcBroker.MAX-REQUESTS - RpcBroker.MAX-TASKS
    tasks ::= capacity + 3  // Create three too many tasks.
    done ::= monitor.Semaphore
    exceptions := 0
    tasks.repeat:
      task::
        exception := catch --unwind=(: it != expected-exception):
          test-simple myself
        if exception == expected-exception: exceptions++
        done.up
    task::
      tasks.repeat: done.down
      expect.expect-equals 3 exceptions

test-blocking myself/int broker/RpcBroker tasks/int [test] -> none:
  name ::= 800
  latches ::= {:}
  ready := monitor.Semaphore
  broker.register-procedure name:: | args |
    index := args[0]
    ready.up
    latches[index].get

  // Create a number of tasks that all block.
  done := monitor.Semaphore
  tasks.repeat:
    index ::= it
    latches[index] = monitor.Latch
    task::
      expect.expect-equals index * 3 (rpc.invoke myself name [index])
      done.up

  // Invoke the test.
  tasks.repeat: ready.down
  test.call

  // Let the tasks complete.
  tasks.repeat: latches[it].set it * 3
  tasks.repeat: done.down

  // Unregister procedure and make sure it's gone.
  broker.unregister-procedure name
  expect.expect-throw "No such procedure registered: 800": rpc.invoke myself name []

test-sequential myself/int broker/RpcBroker -> none:
  tasks ::= 10
  name ::= 800
  latches ::= {:}
  concurrency := 0
  broker.register-procedure name:: | args |
    result := null
    try:
      concurrency++
      expect.expect-equals 1 concurrency  // Should be sequential!
      index := args[0]
      result = latches[index].get
    finally:
      concurrency--
    result

  // Create a number of tasks that all block.
  done := monitor.Semaphore
  tasks.repeat:
    index ::= it
    latches[index] = monitor.Latch
    task::
      expect.expect-equals index * 3 (rpc.invoke myself name --sequential [index])
      done.up

  // Let the tasks complete.
  tasks.repeat:
    sleep --ms=10
    latches[it].set it * 3
  tasks.repeat: done.down

  // Unregister procedure and make sure it's gone.
  broker.unregister-procedure name
  expect.expect-throw "No such procedure registered: 800": rpc.invoke myself name []

test-map myself/int -> none:
  m := {"foo": 42, "bar": [1, 2]}
  test myself m

  // Test the find function on the map.
  roundtripped := rpc.invoke myself PROCEDURE-ECHO m
  expect.expect-structural-equals m["foo"] roundtripped["foo"]
  expect.expect-structural-equals m["bar"] roundtripped["bar"]

  // Reverse order.
  roundtripped = rpc.invoke myself PROCEDURE-ECHO m
  expect.expect-structural-equals m["bar"] roundtripped["bar"]
  expect.expect-structural-equals m["foo"] roundtripped["foo"]

  // Map in map.
  m = {
      "hest": "horse",
      "reptile": {
            "tudse": "toad",
            "t-reks": "t-rex",  // Not really.
      }
  }
  test myself m

  roundtripped = rpc.invoke myself PROCEDURE-ECHO m
  expect.expect-equals "t-rex" roundtripped["reptile"]["t-reks"]

  roundtripped["hest"] = "best"  // Can modify the map after going through RPC.

  // Can't add to the map after going through RPC.  We could fix this in the
  // map class, but it's harder to fix the same issue for growable lists that
  // turn into ungrowable arrays after RPC.
  expect.expect-throw "COLLECTION_CANNOT_CHANGE_SIZE": roundtripped["kat"] = "cat"

  // Empty map in list in list.
  l := [[{:}]]
  test myself l

  // Non-string keys.
  m = {42: "foo"}
  test myself m

cancel queue/RpcRequestQueue_ pid/int id/int -> int:
  result/int := 0
  queue.cancel: | request/RpcRequest_ |
    match/bool := request.pid == pid and request.id == id
    if match: result++
    match
  return result

test-request-queue-cancel myself/int -> none:
  queue := RpcRequestQueue_ 0
  expect.expect-equals 0 queue.unprocessed_
  expect.expect-null queue.first_
  expect.expect-null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 it null:: unreachable)
  expect.expect-equals 10 queue.unprocessed_
  10.repeat:
    expect.expect-equals (10 - it) queue.unprocessed_
    expect.expect-equals 0 (cancel queue (myself + 1) it)  // Try canceling request for other pid.
    expect.expect-equals (10 - it) queue.unprocessed_
    expect.expect-equals 1 (cancel queue myself it)
  expect.expect-equals 0 queue.unprocessed_
  expect.expect-null queue.first_
  expect.expect-null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 it null:: unreachable)
  expect.expect-equals 10 queue.unprocessed_
  10.repeat:
    expect.expect-equals 1 (cancel queue myself (10 - it - 1))
  expect.expect-equals 0 queue.unprocessed_
  expect.expect-null queue.first_
  expect.expect-null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 it null:: unreachable)
  expect.expect-equals 10 queue.unprocessed_
  expect.expect-equals 1 (cancel queue myself 5)
  expect.expect-equals 9 queue.unprocessed_
  expect.expect-equals 0 (cancel queue myself 5)
  expect.expect-equals 9 queue.unprocessed_

  expect.expect-equals 1 (cancel queue myself 7)
  expect.expect-equals 8 queue.unprocessed_
  expect.expect-equals 1 (cancel queue myself 3)
  expect.expect-equals 7 queue.unprocessed_

  10.repeat: cancel queue myself it
  expect.expect-equals 0 queue.unprocessed_
  expect.expect-null queue.first_
  expect.expect-null queue.last_

  10.repeat: queue.add (RpcRequest_ myself -1 42 null:: unreachable)
  expect.expect-equals 10 queue.unprocessed_
  expect.expect-equals 10 (cancel queue myself 42)
  expect.expect-equals 0 queue.unprocessed_
  expect.expect-null queue.first_
  expect.expect-null queue.last_

test-timeouts myself/int broker/RpcBroker --cancel/bool -> none:
  name ::= 801
  latches := {:}
  broker.register-procedure name:: | index |
    try:
      // If a task starts processing this request, we tell the
      // caller to wait for the result.
      latches[index] = monitor.Latch
      // Block until canceled.
      (monitor.Latch).get
    finally:
      if Task.current.is-canceled:
        critical-do: latches[index].set "Canceled: $index"

  // Use 'with_timeout' to trigger the timeout.
  timeout-based/Lambda := :: | index |
    expect.expect-throw DEADLINE-EXCEEDED-ERROR: with-timeout --ms=10:
      latches[index] = monitor.Latch
      latches[index].set "Unprocessed: $index"
      rpc.invoke myself name index

  // Use 'sleep' and 'Task.cancel' to trigger the timeout.
  sleep-cancel-based/Lambda ::= :: | index |
    join := monitor.Latch
    subtask := task::
      latches[index] = monitor.Latch
      latches[index].set "Unprocessed: $index"
      try:
        rpc.invoke myself name index
      finally: | is-exception exception |
        expect.expect Task.current.is-canceled
        critical-do: join.set Task.current
    sleep --ms=10
    subtask.cancel
    expect.expect-identical subtask join.get

  unprocessed := 0
  canceled := 0
  done ::= monitor.Semaphore

  test := :: | index |
    if cancel: sleep-cancel-based.call index
    else: timeout-based.call index
    result := null
    sleep --ms=10  // Allow the RPC tasks to reach their blocking point.
    with-timeout --ms=100: result = latches[index].get
    latches.remove index
    if result == "Unprocessed: $index":
      unprocessed++
    else if result == "Canceled: $index":
      canceled++
    else:
      expect.expect false --message="Unexpected result <$result>"
    done.up

  unprocessed = canceled = 0
  RpcBroker.MAX-REQUESTS.repeat: | index |
    test.call index
  RpcBroker.MAX-REQUESTS.repeat:
    done.down
  expect.expect-equals 0 unprocessed
  expect.expect-equals RpcBroker.MAX-REQUESTS canceled

  unprocessed = canceled = 0
  RpcBroker.MAX-TASKS.repeat: | index |
    task:: test.call index
  RpcBroker.MAX-TASKS.repeat:
    done.down
  expect.expect-equals 0 unprocessed
  expect.expect-equals RpcBroker.MAX-TASKS canceled

  unprocessed = canceled = 0
  RpcBroker.MAX-REQUESTS.repeat: | index |
    task:: test.call index
  RpcBroker.MAX-REQUESTS.repeat:
    done.down
  // It is possible that a canceled processing tasks grabs hold of an
  // unprocessed request and starts processing while we are canceling
  // other requests.
  expect.expect-equals RpcBroker.MAX-REQUESTS (unprocessed + canceled)
  expect.expect canceled >= RpcBroker.MAX-TASKS

  // Unregister procedure and make sure it's gone.
  broker.unregister-procedure name
  expect.expect-throw "No such procedure registered: $name": rpc.invoke myself name []

test-ensure-processing-task myself/int broker/RpcBroker -> none:
  name ::= 802
  broker.register-procedure name:: | index |
    // Block until canceled.
    (monitor.Latch).get

  // Block all processing tasks one-by-one, but cancel them after a little while.
  RpcBroker.MAX-TASKS.repeat:
    expect.expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=50: rpc.invoke myself name []
  with-timeout --ms=200: test myself 42

  // Block all processing tasks at once, but cancel them after a little while.
  done := monitor.Semaphore
  RpcBroker.MAX-TASKS.repeat:
    task::
      expect.expect-throw DEADLINE-EXCEEDED-ERROR:
        with-timeout --ms=50: rpc.invoke myself name []
      done.up
  with-timeout --ms=200: test myself 87
  RpcBroker.MAX-TASKS.repeat: done.down

  // Unregister procedure and make sure it's gone.
  broker.unregister-procedure name
  expect.expect-throw "No such procedure registered: $name": rpc.invoke myself name []

test-terminate myself/int broker/TestBroker -> none:
  test-terminate myself broker 1
  test-terminate myself broker RpcBroker.MAX-TASKS
  test-terminate myself broker RpcBroker.MAX-REQUESTS

test-terminate myself/int broker/TestBroker n/int -> none:
  name ::= 803
  broker.register-procedure name:: | index |
    // Block until canceled.
    (monitor.Latch).get

  // Check that we start under the expected conditions.
  expect.expect-equals 0 broker.queue_.unprocessed_
  expect.expect-null broker.queue_.first_
  expect.expect-null broker.queue_.last_

  // Check that terminating a process and cancelling requests take care
  // of both requests that are enqueued and requests that are being
  // processed.
  broker.reset-terminated
  done := monitor.Semaphore
  n.repeat: task::
    try:
      exception := catch: with-timeout --ms=200: rpc.invoke myself name []
      expect.expect (Task.current.is-canceled or exception == DEADLINE-EXCEEDED-ERROR)
    finally:
      critical-do: done.up

  // Wait a bit and check that all the requests have been enqueued. It is
  // hard to know exactly how long that takes and we get no signals back.
  sleep --ms=20
  expect.expect-equals n broker.queue_.unprocessed_

  // Terminate and wait for the client tasks to stop.
  broker.terminate myself
  n.repeat: done.down

  // Check that we get back to the starting conditions after waiting a
  // bit. The waiting time might not be stricly necessary because after
  // all we know that the client tasks have gotten very close to their
  // termination point.
  sleep --ms=20
  expect.expect-equals 0 broker.queue_.unprocessed_
  expect.expect-null broker.queue_.first_
  expect.expect-null broker.queue_.last_

  // If a task from a dead process has already sent messages to the broker,
  // they are simply discarded.
  finished := monitor.Latch
  dead := task::
    expect.expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=100: test myself 99
    finished.set Task.current
  expect.expect-identical dead finished.get

  // If we revive the process, messages are accepted again.
  broker.reset-terminated
  test myself 87

  // Unregister procedure and make sure it's gone.
  broker.unregister-procedure name
  expect.expect-throw "No such procedure registered: $name": rpc.invoke myself name []

// ----------------------------------------------------------------------------

test myself/int arguments/any:
  expected/any := arguments
  actual/any := ?
  if arguments is MySerializable:
    actual = rpc.invoke myself PROCEDURE-ECHO-WRAPPED arguments
    expected = arguments.serialize-for-rpc
  else:
    actual = rpc.invoke myself PROCEDURE-ECHO arguments
  if arguments is List or arguments is Map:
    expect.expect-structural-equals expected actual
  else:
    expect.expect-equals expected actual

test-cyclic myself/int arguments/any:
  expect.expect-throw "NESTING_TOO_DEEP": rpc.invoke myself PROCEDURE-ECHO arguments

test-serialization-failed myself/int arguments/any:
  expect.expect-throw "SERIALIZATION_FAILED": rpc.invoke myself PROCEDURE-ECHO arguments

test-chain myself/int arguments/any -> List:
  1024.repeat: arguments = rpc.invoke myself PROCEDURE-ECHO arguments
  return arguments

class MyClass:
  // Empty.
