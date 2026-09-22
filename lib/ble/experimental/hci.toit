// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .transport show Transport
import .receive-credits as receive-credits

RESET ::= 0x0c03
SET-EVENT-MASK ::= 0x0c01
READ-VERSION ::= 0x1001
READ-COMMANDS ::= 0x1002
READ-FEATURES ::= 0x1003
READ-BUFFER-SIZE ::= 0x1005
READ-ADDRESS ::= 0x1009
LE-SET-EVENT-MASK ::= 0x2001
LE-READ-BUFFER-SIZE ::= 0x2002
LE-READ-FEATURES ::= 0x2003
SET-CONTROLLER-TO-HOST-FLOW-CONTROL ::= 0x0c31
HOST-BUFFER-SIZE ::= 0x0c33

/** Encodes an HCI command (Core 6.3, Vol 4 Part E, section 5.4.1). */
command-packet opcode/int parameters/ByteArray -> ByteArray:
  if not 1 <= opcode <= 0xffff or parameters.size > 255:
    throw "HCI_INVALID_COMMAND"
  result := ByteArray (4 + parameters.size)
  result[0] = 1
  io.LITTLE-ENDIAN.put-uint16 result 1 opcode
  result[3] = parameters.size
  result.replace 4 parameters
  return result

/** Checks a complete HCI event or ACL packet before accessing its payload. */
validate-packet packet/ByteArray -> none:
  if packet.size < 1: throw "HCI_MALFORMED_PACKET"
  if packet[0] == 4:
    if packet.size < 3 or packet.size != 3 + packet[2]:
      throw "HCI_MALFORMED_PACKET"
  else if packet[0] == 2:
    if packet.size < 5 or packet.size != 5 + (io.LITTLE-ENDIAN.uint16 packet 3):
      throw "HCI_MALFORMED_PACKET"
  else:
    throw "HCI_UNSUPPORTED_PACKET_TYPE"

/** A controller-reported failure, distinct from a transport failure. */
class CommandError:
  opcode/int
  status/int

  constructor .opcode .status:

  stringify -> string:
    return "HCI_COMMAND_FAILED opcode=$opcode status=$status"

/**
A serialized HCI command engine with an independent receive task.

Owns the transport. Call $close deterministically. Command Status only completes
  command submission; callers must separately await the procedure's final event.
*/
class Controller:
  transport_/Transport
  mutex_/monitor.Mutex ::= monitor.Mutex
  credits_/Credits_ ::= Credits_
  incoming_/Packets ::= Packets 32
  reports_/Packets? := null
  pending_/monitor.Latch? := null
  opcode_/int := 0
  status-event_/bool := false
  error_ := null
  close-error_ := null
  reader_/Task? := null
  reader-ended_/monitor.Latch ::= monitor.Latch
  event-owner_ := null
  receive-credits_/receive-credits.ReceiveCredits? := null

  constructor .transport_:
    reader_ = task --background --name="HCI receive"::
      try:
        error := catch: receive-loop_
        if error: fail_ error
      finally:
        critical-do --no-respect-deadline: reader-ended_.set true

  /**
  Sends a command and returns its return parameters, excluding status.

  A timeout or cancellation during submission fails the controller because a
    subsequent late response cannot safely be attributed to another command.
  */
  command opcode/int parameters/ByteArray=#[]
      --timeout/Duration=(Duration --s=3)
      --status-event/bool=false -> ByteArray:
    return command-if opcode parameters --timeout=timeout --status-event=status-event: true

  /**
  Sends a command only if $allowed still holds after serialization and credit wait.

  The scoped predicate must not wait or perform IO. False returns
    HCI_COMMAND_NOT_SENT without consuming a credit or failing the controller.
    It guards the enqueue boundary; transport send may itself wait afterward.
  */
  command-if opcode/int parameters/ByteArray=#[]
      --timeout/Duration=(Duration --s=3)
      --status-event/bool=false [allowed] -> ByteArray:
    packet := command-packet opcode parameters
    return with-timeout timeout:
      mutex_.do:
        check-open_
        completed := false
        try:
          if not (credits_.take-if allowed):
            completed = true
            throw "HCI_COMMAND_NOT_SENT"
          response := monitor.Latch
          pending_ = response
          opcode_ = opcode
          status-event_ = status-event
          transport_.send packet
          result/ByteArray := response.get
          completed = true
          if result.is-empty: throw "HCI_MALFORMED_RESPONSE"
          if result[0] != 0: throw (CommandError opcode result[0])
          return result[1..]
        finally:
          if not completed: fail_ "HCI_COMMAND_ABORTED"

  /** Waits for a non-command event or ACL packet. */
  receive --owner=null -> ByteArray:
    check-open_
    if owner != event-owner_: throw "HCI_EVENTS_OWNED"
    return incoming_.take

  /** Reports whether explicit controller-to-host ACL accounting is enabled. */
  receive-flow-control -> bool: return receive-credits_ != null

  /**
  Processes one received packet and returns its ACL credit on scope exit.

  The $body takes no arguments. It must consume the packet or admit its bytes
    into another bounded stage before returning. With flow control enabled,
    call exactly once for each packet returned by $receive. Credit cleanup has
    its own bounded deadline, including when the consuming task is canceled.
    A failed credit return closes the controller; if $body also fails, its
    original error is preserved for the caller.
  */
  consume packet/ByteArray --owner=null [body]:
    check-open_
    if owner != event-owner_: throw "HCI_EVENTS_OWNED"
    receipt := receive-credits_ and (receive-credits_.find packet)
    completed := false
    try:
      result := body.call
      completed = true
      return result
    finally:
      if receipt:
        if completed:
          return-receipt_ receipt
        else:
          // Cleanup still fails the controller if accounting is uncertain,
          // but must not replace the packet-processing error or cancellation.
          catch: return-receipt_ receipt

  return-receipt_ receipt/receive-credits.Receipt -> none:
    error := catch:
      critical-do --no-respect-deadline:
        with-timeout --ms=3_000:
          sent := false
          if receipt.can-submit:
            sent = transport_.send-if receipt.command:
              receipt.can-submit and not error_
          receipt.finish --submitted=sent
    if error:
      fail_ "HCI_RX_CREDIT_RETURN_FAILED"
      throw error

  configure-receive_ length/int count/int -> none:
    if event-owner_ or receive-credits_: throw "HCI_RX_ALREADY_OWNED"
    receive-credits_ = receive-credits.ReceiveCredits count
    configured := false
    try:
      parameters := ByteArray 7
      io.LITTLE-ENDIAN.put-uint16 parameters 0 length
      io.LITTLE-ENDIAN.put-uint16 parameters 3 count
      require-length_ (command HOST-BUFFER-SIZE parameters) 0
      require-length_ (command SET-CONTROLLER-TO-HOST-FLOW-CONTROL #[1]) 0
      configured = true
    finally:
      if not configured: fail_ "HCI_RX_CONFIGURATION_FAILED"

  observe-receive_ packet/ByteArray -> none:
    credits := receive-credits_
    if not credits: return
    if packet[0] == 2:
      credits.received packet
    else if packet[1] == 5:
      if packet.size != 7 or packet[3] != 0: throw "HCI_RX_INVALID_DISCONNECTION"
      handle := io.LITTLE-ENDIAN.uint16 packet 4
      if handle > 0x0eff: throw "HCI_RX_INVALID_DISCONNECTION"
      credits.disconnected handle
    else if packet[1] == 0x3e and packet.size >= 4:
      kind := packet[3]
      if kind != 1 and kind != 0x0a: return
      if packet.size != (kind == 1 ? 22 : 34): throw "HCI_RX_INVALID_CONNECTION"
      if packet[4] == 0:
        handle := io.LITTLE-ENDIAN.uint16 packet 5
        if handle > 0x0eff: throw "HCI_RX_INVALID_CONNECTION"
        credits.connected handle

  /** Reserves the control/ACL stream for one owning protocol engine. */
  claim-events owner -> none:
    check-open_
    if not owner: throw "INVALID_ARGUMENT"
    if event-owner_: throw "HCI_EVENTS_OWNED"
    event-owner_ = owner

  /** Sends an ACL packet after its owner has reserved a controller credit. */
  send-acl packet/ByteArray [allowed] -> none:
    check-open_
    validate-packet packet
    if packet[0] != 2: throw "HCI_EXPECTED_ACL"
    if not (transport_.send-if packet allowed): throw "HCI_ACL_NOT_SENT"

  /** Reserves bounded legacy scan delivery for one consumer. */
  open-reports --limit/int=32 -> Packets:
    check-open_
    if reports_: throw "HCI_SCAN_BUSY"
    reports_ = Packets limit
    return reports_

  /** Releases scan delivery and wakes its consumer. */
  close-reports reports/Packets -> none:
    critical-do --no-respect-deadline:
      if reports_ != reports: return
      reports_ = null
      reports.fail "HCI_SCAN_CLOSED"

  /** Waits for reader cleanup after close or failure, with a three-second bound. */
  wait-closed -> none:
    if not error_: throw "BLE_OWNER_NOT_CLOSED"
    with-timeout --ms=3_000:
      reader-ended_.get

  /** Reports a retained transport-close failure, including automatic teardown. */
  close-error -> any: return close-error_

  /** Closes the controller and wakes blocked callers. */
  close -> none:
    fail_ "HCI_CLOSED" --propagate-close-error

  check-open_ -> none:
    if error_: throw error_

  fail_ error --propagate-close-error/bool=false -> none:
    critical-do --no-respect-deadline:
      try:
        if error_: return
        error_ = error
        if receive-credits_: receive-credits_.close
        event-owner_ = null
        credits_.fail error
        incoming_.fail error
        if reports_: reports_.fail error
        pending := pending_
        pending_ = null
        if pending: pending.set error --exception
        close-error_ = catch: transport_.close
        // Automatic failure keeps its primary error or cancellation. Explicit
        // close has no earlier failure to preserve and reports cleanup errors.
        if close-error_ and propagate-close-error: throw close-error_
      finally:
        // A failed close may leave receive blocked. Terminate our reader on
        // every failure path, without canceling the reader from itself.
        reader := reader_
        reader_ = null
        if reader and reader != Task.current: reader.cancel

  receive-loop_ -> none:
    count := 0
    while true:
      packet := transport_.receive
      validate-packet packet
      observe-receive_ packet
      if packet[0] == 4 and packet[1] == 0x0e:
        // Command Complete: credits, opcode, return parameters (section 7.7.14).
        if packet.size < 6: throw "HCI_MALFORMED_RESPONSE"
        opcode := io.LITTLE-ENDIAN.uint16 packet 4
        credits_.update packet[3]
        if opcode != 0:
          complete_ opcode false packet[6..]
      else if packet[0] == 4 and packet[1] == 0x0f:
        // Command Status: status, credits, opcode (section 7.7.15).
        if packet.size != 7: throw "HCI_MALFORMED_RESPONSE"
        opcode := io.LITTLE-ENDIAN.uint16 packet 5
        credits_.update packet[4]
        if opcode != 0:
          complete_ opcode true packet[3..4]
      else if packet[0] == 4 and packet[1] == 0x10:
        throw "HCI_HARDWARE_ERROR"
      else if packet[0] == 4 and packet[1] == 0x3e and
          packet.size >= 4 and (packet[3] == 2 or packet[3] == 0x0d):
        // Lossy scan traffic never consumes the control/ACL queue budget.
        if reports_: reports_.add packet --drop-if-full
      else:
        incoming_.add packet
      count++
      if count % 16 == 0: yield

  complete_ opcode/int status-event/bool result/ByteArray -> none:
    pending := pending_
    if not pending or opcode != opcode_:
      throw "HCI_UNEXPECTED_COMMAND_RESPONSE"
    if result.is-empty: throw "HCI_MALFORMED_RESPONSE"
    // An unknown command may be rejected with either response event
    // (section 4.5.1), irrespective of the event expected on success.
    if status-event != status-event_ and result[0] == 0:
      throw "HCI_UNEXPECTED_COMMAND_RESPONSE"
    pending_ = null
    pending.set result

/** A bounded packet queue. Failure wakes readers and releases retained data. */
monitor Packets:
  queue_/List := []
  limit_/int
  error_ := null
  dropped/int := 0

  constructor .limit_:
    if limit_ < 1: throw "INVALID_ARGUMENT"

  add packet/ByteArray --drop-if-full/bool=false -> none:
    if error_: throw error_
    if queue_.size >= limit_:
      if not drop-if-full: throw "HCI_QUEUE_OVERFLOW"
      dropped++
      return
    queue_.add packet

  take -> ByteArray:
    await: error_ or not queue_.is-empty
    if error_: throw error_
    return queue_.remove --at=0

  fail error -> none:
    if error_: return
    error_ = error
    queue_.clear

monitor Credits_:
  count_/int := 1
  error_ := null

  take-if [allowed] -> bool:
    await: error_ or count_ > 0
    if error_: throw error_
    if not allowed.call: return false
    count_--
    return true

  update count/int -> none:
    count_ = count

  fail error -> none:
    error_ = error

/** The baseline controller identity and LE ACL transmit limits. */
class Capabilities:
  version/ByteArray
  commands/ByteArray
  features/ByteArray
  le-features/ByteArray
  address/ByteArray
  acl-length/int
  acl-count/int

  constructor .version .commands .features .le-features .address .acl-length .acl-count:

/**
Initializes the controller for the initial, legacy LE feature set.

Nonzero $receive-acl-packets explicitly enables controller-to-host ACL credits.
  The caller must reserve transport space for these packets plus control events;
  the generic upper bound of 32 is not a native capacity guarantee. Each received
  packet must pass through $Controller.consume after bounded consumption. Both
  byte length and count describe host receive capacity, not controller TX credits.
  Configure only before assigning a protocol owner. Unsupported commands fail
  explicitly; ambiguous setup failure closes the controller.
*/
initialize controller/Controller --receive-acl-packets/int=0 --receive-acl-length/int=1024 -> Capabilities:
  if not 0 <= receive-acl-packets <= 32 or not 1 <= receive-acl-length <= 1024:
    throw "INVALID_ARGUMENT"
  if controller.receive-flow-control: throw "HCI_RX_ALREADY_OWNED"
  if receive-acl-packets != 0 and controller.event-owner_: throw "HCI_RX_ALREADY_OWNED"
  require-length_ (controller.command RESET) 0
  version := require-length_ (controller.command READ-VERSION) 8
  commands := require-length_ (controller.command READ-COMMANDS) 64
  features := require-length_ (controller.command READ-FEATURES) 8
  if features[4] & 0x40 == 0: throw "HCI_LE_NOT_SUPPORTED"
  address := require-length_ (controller.command READ-ADDRESS) 6
  le-features := require-length_ (controller.command LE-READ-FEATURES) 8
  buffers := require-length_ (controller.command LE-READ-BUFFER-SIZE) 3
  acl-length := io.LITTLE-ENDIAN.uint16 buffers 0
  acl-count := buffers[2]
  if acl-count == 0:
    // Shared BR/EDR and LE buffers (Vol 4 Part E, section 7.8.2).
    shared := require-length_ (controller.command READ-BUFFER-SIZE) 7
    acl-length = io.LITTLE-ENDIAN.uint16 shared 0
    acl-count = io.LITTLE-ENDIAN.uint16 shared 3
  if acl-length == 0 or acl-count == 0: throw "HCI_INVALID_BUFFER_LIMITS"
  // Disconnect, encryption change/refresh, hardware error, completed packets, LE meta.
  controller.command SET-EVENT-MASK #[0x90, 0x80, 0x04, 0, 0, 0x80, 0, 0x20]
  // Legacy LE connection, advertising, update, features, and key request events.
  controller.command LE-SET-EVENT-MASK #[0x1f, 0, 0, 0, 0, 0, 0, 0]
  if receive-acl-packets != 0:
    if commands[10] & 0xe0 != 0xe0: throw "HCI_RX_FLOW_UNSUPPORTED"
    controller.configure-receive_ receive-acl-length receive-acl-packets
  return Capabilities version commands features le-features address acl-length acl-count

require-length_ bytes/ByteArray length/int -> ByteArray:
  if bytes.size != length: throw "HCI_MALFORMED_RESPONSE"
  return bytes
