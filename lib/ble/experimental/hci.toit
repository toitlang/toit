// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .cancellation show checkpoint
import .transport show Transport
import .receive-credits as receive-credits
import .timeouts as timeouts

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
LE-WRITE-SUGGESTED-DEFAULT-DATA-LENGTH ::= 0x2024
LE-SET-DEFAULT-PHY ::= 0x2031
LE-SET-PHY ::= 0x2032
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

The engine owns every pending command (docs/ble/design.md, cancellation
  contract): a caller that stops waiting, because it was cancelled or its
  deadline passed, detaches, and the engine still attributes and consumes the
  response and restores the command credit. Only a response that never arrives
  within the command's own bound fails the controller; a dedicated deadline
  task enforces that bound so it holds after every caller has left.
*/
class Controller:
  transport_/Transport
  engine_/Engine_ ::= Engine_
  incoming_/Packets ::= Packets 32
  reports_/Packets? := null
  error_ := null
  close-error_ := null
  reader_/Task? := null
  reader-ended_/monitor.Latch ::= monitor.Latch
  timer_/Task? := null
  timer-ended_/monitor.Latch ::= monitor.Latch
  event-owner_ := null
  receive-credits_/receive-credits.ReceiveCredits? := null

  constructor .transport_:
    reader_ = task --background --name="HCI receive"::
      try:
        error := catch: receive-loop_
        if error: fail_ error
      finally:
        critical-do --no-respect-deadline: reader-ended_.set true
    // The engine, not the caller, decides that the controller stopped
    // answering: this task fails the controller when a pending command
    // outlives its bound, whether or not anyone still waits for it.
    timer_ = task --background --name="HCI deadlines"::
      try:
        error := catch: deadline-loop_
        if error: fail_ error
      finally:
        critical-do --no-respect-deadline: timer-ended_.set true

  /**
  Sends a command and returns its return parameters, excluding status.

  Submission is atomic. The wait for the response is not: a cancelled caller or
    one whose deadline passes leaves immediately, and the engine settles the
    command on its own. $timeout bounds the controller's answer; expiry fails
    the controller because ownership of its next response is then uncertain.
  */
  command opcode/int parameters/ByteArray=#[]
      --timeout/Duration=timeouts.COMMAND
      --status-event/bool=false -> ByteArray:
    return command-if opcode parameters --timeout=timeout --status-event=status-event: true

  /**
  Sends a command only if $allowed still holds after serialization and credit wait.

  The scoped predicate must not wait or perform IO. False returns
    HCI_COMMAND_NOT_SENT without consuming a credit or failing the controller.
    Otherwise behaves like $command.
  */
  command-if opcode/int parameters/ByteArray=#[]
      --timeout/Duration=timeouts.COMMAND
      --status-event/bool=false [allowed] -> ByteArray:
    return (submit-if opcode parameters --timeout=timeout --status-event=status-event allowed).wait

  /**
  Submits a command and returns its pending response without waiting.

  Submission is atomic; once this returns, the command is with the controller
    and $Pending.wait can be called, abandoned, or retried by any task. A
    procedure whose completion has side effects (creating a connection,
    starting encryption) submits explicitly so it knows the command is out
    even if it is cancelled before the response.
  */
  submit opcode/int parameters/ByteArray=#[]
      --timeout/Duration=timeouts.COMMAND
      --status-event/bool=false -> Pending:
    return submit-if opcode parameters --timeout=timeout --status-event=status-event: true

  /** Like $submit, guarded by $allowed at the submission boundary. */
  submit-if opcode/int parameters/ByteArray=#[]
      --timeout/Duration=timeouts.COMMAND
      --status-event/bool=false [allowed] -> Pending:
    packet := command-packet opcode parameters
    check-open_
    deadline := Time.monotonic-us + timeout.in-us
    // Everything the command needs exists before the slot is reserved, so an
    // allocation failure cannot strand a reserved slot or a sent packet.
    latch := monitor.Latch
    pending := Pending opcode latch
    if not (engine_.acquire latch opcode status-event deadline allowed): throw "HCI_COMMAND_NOT_SENT"
    sent := false
    try:
      // An interrupted transport send leaves ownership of the next response
      // unknown, so submission runs to completion regardless of the caller.
      critical-do --no-respect-deadline: transport_.send packet
      sent = true
    finally:
      if not sent: fail_ "HCI_COMMAND_ABORTED"
    return pending

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
        with-timeout timeouts.CLEANUP:
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
    with-timeout timeouts.JOIN:
      reader-ended_.get
      timer-ended_.get

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
        engine_.fail error
        incoming_.fail error
        if reports_: reports_.fail error
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
        timer := timer_
        timer_ = null
        if timer and timer != Task.current: timer.cancel

  deadline-loop_ -> none:
    while true:
      deadline := engine_.wait-pending
      if not engine_.wait-settled deadline: throw "HCI_COMMAND_ABORTED"

  receive-loop_ -> none:
    count := 0
    while true:
      packet := transport_.receive
      validate-packet packet
      observe-receive_ packet
      if packet[0] == 4 and packet[1] == 0x0e:
        // Command Complete: credits, opcode, return parameters (section 7.7.14).
        if packet.size < 6: throw "HCI_MALFORMED_RESPONSE"
        engine_.settle (io.LITTLE-ENDIAN.uint16 packet 4) false packet[6..] packet[3]
      else if packet[0] == 4 and packet[1] == 0x0f:
        // Command Status: status, credits, opcode (section 7.7.15).
        if packet.size != 7: throw "HCI_MALFORMED_RESPONSE"
        engine_.settle (io.LITTLE-ENDIAN.uint16 packet 5) true packet[3..4] packet[4]
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

/** A submitted command whose response can be awaited by any task, any number of times. */
class Pending:
  opcode/int
  latch_/monitor.Latch

  constructor .opcode .latch_:

  /** Waits for the response; returns the return parameters excluding status. */
  wait -> ByteArray:
    result/ByteArray := latch_.get
    if result[0] != 0: throw (CommandError opcode result[0])
    return result[1..]

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

/**
The command slot: one credit and at most one pending command.

Serializes callers, settles responses delivered by the receive task and keeps
  the pending command's deadline for that task to enforce.
*/
monitor Engine_:
  credits_/int := 1
  pending_/monitor.Latch? := null
  opcode_/int := 0
  status-event_/bool := false
  deadline_/int := 0
  error_ := null

  /** Reserves the slot for $latch; false when $allowed declines at the boundary. */
  acquire latch/monitor.Latch opcode/int status-event/bool deadline/int [allowed] -> bool:
    await: error_ or (credits_ > 0 and pending_ == null)
    if error_: throw error_
    if not allowed.call: return false
    credits_--
    pending_ = latch
    opcode_ = opcode
    status-event_ = status-event
    deadline_ = deadline
    return true

  /** Applies a response from the receive task; opcode zero only updates credits. */
  settle opcode/int status-event/bool result/ByteArray credits/int -> none:
    credits_ = credits
    if opcode == 0: return
    pending := pending_
    if not pending or opcode != opcode_: throw "HCI_UNEXPECTED_COMMAND_RESPONSE"
    if result.is-empty: throw "HCI_MALFORMED_RESPONSE"
    // An unknown command may be rejected with either response event
    // (section 4.5.1), irrespective of the event expected on success.
    if status-event != status-event_ and result[0] == 0:
      throw "HCI_UNEXPECTED_COMMAND_RESPONSE"
    pending_ = null
    pending.set result

  /** Waits until a command is pending and returns its deadline. */
  wait-pending -> int:
    await: error_ or pending_ != null
    if error_: throw error_
    return deadline_

  /**
  Waits until the pending command with $deadline settled; false on expiry.

  A later command with a new deadline counts as settled for this wait.
  */
  wait-settled deadline/int -> bool:
    return try-await --deadline=deadline: error_ or pending_ == null or deadline_ != deadline

  fail error -> none:
    if error_: return
    error_ = error
    pending := pending_
    pending_ = null
    if pending: pending.set error --exception

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

  /** Whether the controller supports the LE 2M PHY and LE Set PHY. */
  phy-2m -> bool: return le-features[1] & 0x01 != 0 and commands[35] & 0x40 != 0

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
  // Each command is atomic; a cancelled caller leaves between commands.
  require-length_ (controller.command RESET) 0
  checkpoint
  version := require-length_ (controller.command READ-VERSION) 8
  checkpoint
  commands := require-length_ (controller.command READ-COMMANDS) 64
  checkpoint
  features := require-length_ (controller.command READ-FEATURES) 8
  if features[4] & 0x40 == 0: throw "HCI_LE_NOT_SUPPORTED"
  checkpoint
  address := require-length_ (controller.command READ-ADDRESS) 6
  checkpoint
  le-features := require-length_ (controller.command LE-READ-FEATURES) 8
  checkpoint
  buffers := require-length_ (controller.command LE-READ-BUFFER-SIZE) 3
  checkpoint
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
  checkpoint
  // Legacy LE connection, advertising, update, features, key request and
  // data length change events.
  controller.command LE-SET-EVENT-MASK #[0x5f, 0x08, 0, 0, 0, 0, 0, 0]
  checkpoint
  // Data Length Extension (Vol 6 Part B 4.5.10): a controller that supports it
  // initiates the length update on every new connection from these defaults,
  // so 251-octet link-layer PDUs need no per-connection command.
  if le-features[0] & 0x20 != 0 and commands[33] & 0x40 != 0:
    controller.command LE-WRITE-SUGGESTED-DEFAULT-DATA-LENGTH #[0xfb, 0x00, 0x48, 0x08]
    checkpoint
  // LE 2M PHY (Vol 6 Part B 4.6.9): prefer 1M or 2M in both directions for
  // connections this controller negotiates; a link owner asks for 2M after
  // a connection it initiated ($Capabilities.phy-2m).
  if le-features[1] & 0x01 != 0 and commands[35] & 0x20 != 0:
    controller.command LE-SET-DEFAULT-PHY #[0, 0x03, 0x03]
    checkpoint
  if receive-acl-packets != 0:
    if commands[10] & 0xe0 != 0xe0: throw "HCI_RX_FLOW_UNSUPPORTED"
    controller.configure-receive_ receive-acl-length receive-acl-packets
  return Capabilities version commands features le-features address acl-length acl-count

require-length_ bytes/ByteArray length/int -> ByteArray:
  if bytes.size != length: throw "HCI_MALFORMED_RESPONSE"
  return bytes
