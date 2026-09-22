// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.native
import ble.experimental.hci
import expect show *
import host.directory
import monitor
import system

// Explicit test-build fixture. No Bluetooth adapter or capability is used.
main args/List:
  if args == ["disabled"]:
    expect-throw "UNIMPLEMENTED": native.testing-pair
    group := init_
    [1, 2].do: | action/int |
      expect-throw "UNIMPLEMENTED": test_ group action
    print "NATIVE_LINUX DISABLED"
    return
  if not args.is-empty: throw "INVALID_ARGUMENT"
  with-timeout --ms=30_000:
    roundtrip
    sleep --ms=10
    baseline := descriptors
    20.repeat:
      roundtrip
      foreign-close
      deadline-close
      canceled-close
      allocation-retry
      close-reader
      peer-close
      peer-close --writer
      blocked-writer
      blocked-writer --cancel
      canceled-reader
      controller-exchange
      oversized
      system.process-stats --gc
      with-timeout --ms=1_000:
        while descriptors != baseline: sleep --ms=1
    print "NATIVE_LINUX COMPLETE cycles=20 descriptors=$baseline"

// Native teardown must complete when called while unwinding an expired scope.
deadline-close:
  pair := native.testing-pair
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  try:
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=1:
        try:
          sleep --ms=100
        finally:
          left.close
    expect-throw "HCI_CLOSED": left.send #[1]
    error := catch: with-timeout --ms=100: right.receive
    expect-equals "HCI_TRANSPORT_ERROR" error
  finally:
    left.close
    right.close

canceled-close:
  pair := native.testing-pair
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  started := monitor.Latch
  ended := monitor.Latch
  worker := task::
    try:
      started.set true
      left.receive
    finally:
      try:
        left.close
      finally:
        critical-do --no-respect-deadline: ended.set true
  try:
    started.get
    sleep --ms=1
    worker.cancel
    with-timeout --ms=1_000: ended.get
    expect-throw "HCI_CLOSED": left.send #[1]
    error := catch: with-timeout --ms=100: right.receive
    expect-equals "HCI_TRANSPORT_ERROR" error
  finally:
    worker.cancel
    left.close
    right.close

foreign-close:
  owner := init_
  foreign := init_
  pair/List := test_ owner 0
  rejected := false
  try:
    // A rejected close must retain the proxy and both packet directions.
    expect-throw "INVALID_ARGUMENT": close_ foreign pair[0]
    rejected = true
    expect (send_ pair[0] #[17, 18])
    expect-equals #[17, 18] (receive_ pair[1] 2048)
    system.process-stats --gc
    expect (send_ pair[1] #[19, 20])
    expect-equals #[19, 20] (receive_ pair[0] 2048)
  finally:
    // A pre-fix VM clears the first proxy despite not closing its descriptor.
    // Preserve the assertion failure; group cleanup owns any remaining socket.
    pair.do: | resource |
      if rejected: close_ owner resource
      else: catch: close_ owner resource

// A dedicated group prevents another fixture's reader from consuming the
// group-local injection. Direct primitives let us check an empty queue exactly.
allocation-retry:
  group := init_
  pair/List := test_ group 0
  try:
    left := pair[0]
    right := pair[1]
    first := #[4, 14, 4, 1, 9, 16, 0]
    expected := first.copy
    second := #[2, 1, 0, 3, 0, 7, 8, 9]
    expect (send_ left first)
    expect (send_ left second)
    first.fill 99
    before := system.process-stats --gc
    test_ group 1
    received := receive_ right 2048
    failures/int := test_ group 2
    after := system.process-stats
    expect (failures > 0)
    expect (after[system.STATS-INDEX-FULL-GC-COUNT] > before[system.STATS-INDEX-FULL-GC-COUNT])
    expect-equals expected received
    expect-equals second (receive_ right 2048)
    expect-equals null (receive_ right 2048)
    system.process-stats --gc
    expect-equals expected received
  finally:
    pair.do: close_ group it

init_:
  #primitive.ble_hci.init

test_ group action/int:
  return test-packet_ group action #[]

test-packet_ group action/int packet/ByteArray:
  #primitive.ble_hci.test

send_ resource packet/ByteArray -> bool:
  #primitive.ble_hci.send

receive_ resource limit/int -> ByteArray?:
  #primitive.ble_hci.receive

close_ group resource:
  #primitive.ble_hci.close

descriptors -> int:
  entries := directory.DirectoryStream "/proc/self/fd"
  count := 0
  while entries.next: count++
  return count

roundtrip:
  pair := native.testing-pair
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  retained := []
  try:
    [1, 7, 64, 2048].do: | size/int |
      payload := ByteArray size: it & 0xff
      expected := payload.copy
      left.send payload
      payload.fill 0xa5
      system.process-stats --gc
      received := right.receive
      expect-equals expected received
      retained.add [expected, received]
      right.send received
      expect-equals expected left.receive
    expect (not (left.send-if #[42]: false))
    left.send #[43]
    expect-equals #[43] right.receive
    system.process-stats --gc
    retained.do: expect-equals it[0] it[1]
  finally:
    left.close
    right.close
    left.close
    expect-throw "HCI_CLOSED": left.send #[1]
    expect-throw "HCI_CLOSED": right.receive

// Exercise EPOLLHUP/ERR from the other endpoint, rather than disposing the
// waiting resource locally. This is not an AF_BLUETOOTH USB-unplug simulation.
peer-close --writer/bool=false:
  pair := native.testing-pair
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  entered := monitor.Latch
  ended := monitor.Latch
  sent := 0
  worker := task::
    entered.set true
    error := catch:
      if writer:
        256.repeat:
          right.send (ByteArray 2048 --initial=42)
          sent++
      else:
        right.receive
    ended.set error
  try:
    entered.get
    sleep --ms=10
    expect (not ended.has-value)
    if writer: expect (sent > 0 and sent < 256)
    left.close
    with-timeout --ms=1_000:
      expect-equals "HCI_TRANSPORT_ERROR" ended.get
  finally:
    worker.cancel
    left.close
    right.close

close-reader:
  pair := native.testing-pair
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  started := monitor.Latch
  ended := monitor.Latch
  reader := task::
    started.set true
    error := catch: right.receive
    ended.set error
  try:
    started.get
    sleep --ms=1
    right.close
    with-timeout --ms=1_000: expect-equals "HCI_CLOSED" ended.get
  finally:
    reader.cancel
    left.close
    right.close

blocked-writer --cancel/bool=false:
  pair := native.testing-pair
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  started := monitor.Latch
  ended := monitor.Latch
  sent := 0
  writer := task::
    started.set true
    error := null
    try:
      error = catch:
        256.repeat:
          left.send (ByteArray 2048 --initial=42)
          sent++
    finally:
      critical-do --no-respect-deadline: ended.set error
  try:
    started.get
    sleep --ms=10
    expect (sent > 0 and sent < 256 and not ended.has-value)
    if cancel:
      writer.cancel
      with-timeout --ms=1_000: expect-equals null ended.get
      sent.repeat: expect-equals (ByteArray 2048 --initial=42) right.receive
      left.send #[99]
      expect-equals #[99] right.receive
    else:
      left.close
      with-timeout --ms=1_000: expect-equals "HCI_CLOSED" ended.get
  finally:
    writer.cancel
    left.close
    right.close

canceled-reader:
  pair := native.testing-pair
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  entered := monitor.Latch
  ended := monitor.Latch
  reader := task::
    try:
      entered.set true
      right.receive
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    entered.get
    sleep --ms=1
    reader.cancel
    with-timeout --ms=1_000: ended.get
    left.send #[17]
    expect-equals #[17] right.receive
  finally:
    reader.cancel
    left.close
    right.close

controller-exchange:
  pair := native.testing-pair
  peer/native.NativeTransport := pair[1]
  controller := hci.Controller pair[0]
  done := monitor.Latch
  responder := task::
    expect-equals #[1, 3, 12, 0] peer.receive
    peer.send #[4, 14, 4, 1, 3, 12, 0]
    done.set true
  try:
    expect-equals #[] (controller.command 0x0c03)
    done.get
    peer.send #[4, 14, 1, 0]
    expect-throw "HCI_MALFORMED_RESPONSE": controller.receive
  finally:
    responder.cancel
    controller.close
    controller.wait-closed
    peer.close

oversized:
  pair := native.testing-pair --packet-limit=64
  left/native.NativeTransport := pair[0]
  right/native.NativeTransport := pair[1]
  try:
    left.send (ByteArray 65)
    // A refused front packet remains queued; it is not truncated or consumed.
    2.repeat: expect-throw "OUT_OF_RANGE": right.receive
  finally:
    left.close
    right.close
