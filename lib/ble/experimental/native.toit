// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import io

import .transport show Transport

READ_ ::= 1
WRITE_ ::= 2
ERROR_ ::= 4

/** A packet transport backed by the platform's native HCI resource. */
class NativeTransport implements Transport:
  state_/ResourceState_? := null
  reader_/monitor.Mutex ::= monitor.Mutex
  writer_/monitor.Mutex ::= monitor.Mutex
  limit_/int

  constructor adapter/int --packet-limit/int=2048:
    limit_ = packet-limit
    if not 1 <= packet-limit <= 2048: throw "INVALID_ARGUMENT"
    initialize_ adapter

  /** Opens Linux's management channel; packets have management framing. */
  constructor.management --packet-limit/int=2048:
    limit_ = packet-limit
    if not 1 <= packet-limit <= 2048: throw "INVALID_ARGUMENT"
    initialize_ 0 --management

  constructor.from-resource_ resource --packet-limit/int:
    limit_ = packet-limit
    state_ = ResourceState_ group_ resource
    add-finalizer this:: close

  initialize_ adapter/int --management/bool=false -> none:
    // Enter the protected scope before acquiring a native resource: even
    // creating the helper's call frame can fail under heap pressure.
    resource := null
    completed := false
    try:
      resource = management ? (open-management_ group_) : (open_ group_ adapter)
      state_ = ResourceState_ group_ resource
      add-finalizer this:: close
      completed = true
    finally:
      if resource and not completed:
        critical-do --no-respect-deadline:
          state := state_
          state_ = null
          try:
            if state: state.dispose
          finally:
            remove-finalizer this
            close_ group_ resource

  receive -> ByteArray:
    return reader_.do:
      while true:
        state := require-state_
        state.clear-state READ_ | ERROR_
        packet/ByteArray? := null
        error := catch: packet = receive_ state.resource limit_
        if error: throw-transport-error_ error
        if packet: return packet
        bits := state.wait-for-state READ_ | ERROR_
        require-state_
        if bits & ERROR_ != 0: throw-transport-error_ "HCI_TRANSPORT_ERROR"
      unreachable

  send packet/ByteArray -> none:
    send-if packet: true

  send-if packet/ByteArray [allowed] -> bool:
    return writer_.do:
      while true:
        state := require-state_
        state.clear-state WRITE_ | ERROR_
        if not allowed.call: return false
        sent := false
        error := catch: sent = send_ state.resource packet
        if error: throw-transport-error_ error
        if sent: return true
        bits := state.wait-for-state WRITE_ | ERROR_
        require-state_
        if bits & ERROR_ != 0: throw-transport-error_ "HCI_TRANSPORT_ERROR"

  /**
  Samples native receive-queue diagnostics, or returns null when unavailable.

  Requires an open transport. Fields are sampled independently; callbacks may
    continue producing while the sample is collected. Counters reset on reopen.
  */
  diagnostics -> QueueDiagnostics?:
    bytes := diagnostics_ require-state_.resource
    return bytes ? (QueueDiagnostics bytes) : null

  // Preserve terminal queue faults in both immediate and wakeup error paths.
  // Diagnostics are optional and sampled only after failure. A sampling failure
  // must not replace the transport error; other primitive exceptions retain
  // their original meaning (including argument and allocation failures).
  throw-transport-error_ error -> none:
    if error != "ERROR" and error != "HCI_TRANSPORT_ERROR": throw error
    sample/QueueDiagnostics? := null
    catch: sample = diagnostics
    throw ((sample and sample.fault) or "HCI_TRANSPORT_ERROR")

  close -> none:
    // Once the state is detached, cancellation must not interrupt monitor
    // disposal and strand the native resource behind an already-closed proxy.
    critical-do --no-respect-deadline:
      state := state_
      if not state: return
      state_ = null
      resource := state.resource
      state.dispose
      try:
        close_ group_ resource
      finally:
        remove-finalizer this

  require-state_ -> ResourceState_:
    state := state_
    if not state: throw "HCI_CLOSED"
    return state

group_ := init_

/**
Creates two connected Linux packet transports for explicit native regression tests.

Requires a host built with TOIT_BLE_HCI_TESTING. Normal builds reject this call.
  The sockets exercise native packet IO and resource ownership, not HCI adapter
  binding or controller behavior. The caller must close both returned transports.
*/
testing-pair --packet-limit/int=2048 -> List:
  if not 1 <= packet-limit <= 2048: throw "INVALID_ARGUMENT"
  result := List 2
  resources/List := test_ group_ 0 #[]
  completed := false
  try:
    2.repeat:
      result[it] = NativeTransport.from-resource_ resources[it] --packet-limit=packet-limit
    completed = true
    return result
  finally:
    if not completed:
      critical-do --no-respect-deadline:
        2.repeat:
          if result[it]: result[it].close
          else: close_ group_ resources[it]

/**
Stops an ESP32 controller before close, only in isolated fault-test firmware.

Leaves the native ownership flag stale to exercise a real SDK shutdown error.
  The caller must close the transport afterward. Normal firmware rejects this
  operation with UNIMPLEMENTED. It is not a controller recovery API.
*/
testing-stop-controller radio/NativeTransport --deinitialize/bool=false -> none:
  status := test_ radio.require-state_.resource (deinitialize ? 4 : 3) #[]
  if status != 0: throw "HCI_TEST_STOP_FAILED $status"

test_ group action/int packet/ByteArray:
  #primitive.ble_hci.test

init_:
  #primitive.ble_hci.init

open_ group adapter/int:
  #primitive.ble_hci.open

open-management_ group:
  #primitive.ble_hci.open_management

receive_ resource limit/int -> ByteArray?:
  #primitive.ble_hci.receive

send_ resource packet/ByteArray -> bool:
  #primitive.ble_hci.send

close_ group resource -> none:
  #primitive.ble_hci.close

diagnostics_ resource -> ByteArray?:
  #primitive.ble_hci.diagnostics

/** A sample of the native receive queue, with storage owned by this sample. */
class QueueDiagnostics:
  bytes_/ByteArray

  constructor .bytes_:

  /** Returns the queue capacity in packets. */
  capacity -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 0
  /** Returns the sampled number of queued packets. */
  queued -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 4
  /** Returns a conservative peak packet count since open. */
  high-water -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 8
  /** Returns the advertising-report drop count, modulo 2^32. */
  scan-drops -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 12
  /** Returns null, or the terminal native queue fault. */
  fault -> string?:
    code := io.LITTLE-ENDIAN.uint32 bytes_ 16
    if code == 0: return null
    if code == 1: return "HCI_INVALID_PACKET"
    if code == 2: return "HCI_OVERSIZED_PACKET"
    if code == 3: return "HCI_QUEUE_OVERFLOW"
    return "HCI_UNKNOWN_QUEUE_FAULT"

tx-power_ action/int dbm/int -> int?:
  #primitive.ble_hci.tx_power
