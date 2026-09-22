// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor

import .attribute-server as attributes
import .cccd-store as cccd
import .central as central
import .signaling as signaling
import .security-owner as security

/** A submitted indication whose protocol confirmation can be awaited. */
class Indication:
  completed_/monitor.Latch ::= monitor.Latch
  serving-task_/Task? := ?

  constructor .serving-task_:

  /** Reports whether confirmation or a terminal error has arrived. */
  is-complete -> bool: return completed_.has-value

  /**
  Waits for confirmation, or throws on timeout, disconnect, or server close.

  Cannot be called inside this server's serving block: that task must return
    to receiving before it can process a confirmation. Canceling a waiter does
    not retract the indication; its deadline and ownership remain with the server.
  */
  wait -> none:
    if Task.current == serving-task_: throw "GATT_INDICATION_WAIT_IN_SERVE"
    completed_.get

/** A fixed-layout GATT server for one link, with scoped application hooks. */
class Server:
  pairing_/security.Owner?
  host_/central.Central
  link_/central.Link
  session_/attributes.Session
  serving_/bool := false
  closed_/bool := false
  serving-task_/Task? := null
  disconnect-watcher_/Task? := null
  handling_/bool := false
  parameter-status_/string? := null
  parameter-timer_/Task? := null
  indication_/Indication? := null
  indication-timer_/Task? := null
  change-indication_/bool := false
  security-ready_/bool := false

  constructor .host_ .link_ database/attributes.Database --pairing/security.Owner?=null
      --handler-timeout/Duration=(Duration --s=1) --cccd-store/cccd.Store?=null:
    pairing_ = pairing
    if pairing and not (pairing.matches host_ link_): throw "SMP_WRONG_LINK"
    if database.mtu-limit > link_.receive-limit: throw "GATT_MTU_EXCEEDS_LINK_LIMIT"
    if not (host_.owns-link link_): throw "HCI_INVALID_LINK"
    session_ = database.session --security=pairing --handler-timeout=handler-timeout --cccd-store=cccd-store
    link_.claim-receive this

  /** Returns the session's negotiated ATT MTU. */
  mtu -> int: return session_.mtu

  /**
  Sends a retained Service Changed notice after trusted security setup completes.

  Call after the security owner's run, including durable bond admission. The
    service provider calls this automatically. If serving has not started yet,
    the notice is deferred until it does. The pending flag is cleared durably
    only after confirmation; disconnect or send failure leaves it for reconnect.
  */
  security-ready -> none:
    check-open_
    security-ready_ = true
    send-change_

  send-change_ -> none:
    if serving_ and security-ready_ and session_.service-changed-pending and not change-indication_:
      indicate session_.service-changed-handle

  /**
  Submits one peripheral interval request while allowing ATT serving to continue.

  The serve loop processes the response. Acceptance is the peer's signaling
    decision, not evidence that the controller applied the new parameters.
    A single timeout task exists only while this request is pending.
  */
  request-parameters --interval/int=12 --timeout/Duration=(Duration --s=30) -> none:
    check-open_
    if link_.info.role != 1: throw "GATT_NOT_PERIPHERAL"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    if parameter-status_: throw "L2CAP_PARAMETER_REQUEST_ALREADY_SENT"
    request := signaling.parameter-request 1 --interval=interval
    parameter-status_ = "pending"
    parameter-timer_ = task --background::
      sleep timeout
      if parameter-status_ == "pending": parameter-status_ = "timeout"
      parameter-timer_ = null
    submitted := false
    try:
      host_.send link_ 5 request
      submitted = true
    finally:
      if not submitted: close

  /** Returns null, pending, accepted, rejected, timeout, or closed. */
  parameter-status -> string?: return parameter-status_

  /**
  Serves until peer disconnect, calling $written after each acknowledged write.

  The block receives the handle and an owned value, including CCCD writes.
    Execute Write reports the final value once per affected handle.
    It may yield and publish notifications. The acknowledgement precedes the
    block, so the block cannot reject a write. Use $serve-with-reads for
    dynamic read replies or $serve-with-requests for pre-commit write validation.
    Exceptions/cancellation abort the link (closing an exclusive owner).
    Normal peer disconnect leaves the owner available for another link.
  */
  serve [written] -> none:
    serve-with-reads (: | request/attributes.ReadRequest | request.reject 0x0e) written

  /**
  Serves with a scoped dynamic-read handler and an accepted-write hook.

  Disconnect during an application block invalidates its request and cancels
    the serving task. Use finally for application cleanup. Disconnect while
    waiting for protocol input returns normally. The link owner remains usable
    by another task after a peer disconnect.
  */
  serve-with-reads [read] [written] -> none:
    serve-with-requests read (: | request/attributes.WriteRequest | request.reject 0x0e) written

  /**
  Serves scoped reads, pre-commit write validation, and accepted-write hooks.

  Processing one ATT PDU, including its response submission and accepted-write
    hooks, has a ten-second aggregate bound. Expiry terminates the link even if
    each individual handler fits its own budget. Already committed writes are
    not rolled back. This bounds serving work, not time spent in ingress queues.
  */
  serve-with-requests [read] [validate] [written] -> none:
    check-open_
    if serving_: throw "GATT_ALREADY_SERVING"
    serving_ = true
    serving-task_ = Task.current
    disconnect-watcher_ = task --background::
      catch: link_.wait-disconnected
      critical-do --no-respect-deadline:
        if handling_ and serving-task_:
          session_.close
          serving-task_.cancel
    try:
      error := catch:
        send-change_
        receive-loop_ read validate written
      if error and error != "HCI_LINK_DISCONNECTED": throw error
    finally:
      critical-do --no-respect-deadline:
        if disconnect-watcher_: disconnect-watcher_.cancel
        disconnect-watcher_ = null
        serving-task_ = null
        close

  /**
  Submits the current value as a notification if this peer subscribed.

  Set $truncate false to require the whole value to fit the negotiated MTU.
    Oversize rejection occurs before transport submission and keeps the link open.
  */
  notify handle/int --truncate/bool=true -> bool:
    check-open_
    packet := session_.notification handle --truncate=truncate
    if not packet: return false
    host_.send link_ 4 packet
    return true

  /**
  Submits a value snapshot, returning a receipt or null when not subscribed.

  Only one indication may await confirmation on this link. A second submission
    throws GATT_INDICATION_BUSY. The serving loop must be running to receive
    confirmation. The deadline is at most thirty seconds; expiration or an
    interrupted send aborts the link, preventing ambiguous late confirmations.
  */
  indicate handle/int --timeout/Duration=(Duration --s=30) --truncate/bool=true -> Indication?:
    check-open_
    if timeout.in-us <= 0 or timeout.in-us > 30_000_000: throw "INVALID_ARGUMENT"
    if not serving_: throw "GATT_NOT_SERVING"
    if indication_: throw "GATT_INDICATION_BUSY"
    packet := session_.indication handle --truncate=truncate
    if not packet: return null
    receipt := Indication serving-task_
    submitted := false
    try:
      indication_ = receipt
      change-indication_ = handle == session_.service-changed-handle and session_.service-changed-pending
      indication-timer_ = task --background::
        sleep timeout
        indication-timer_ = null
        finish-indication_ "GATT_INDICATION_TIMEOUT"
        close
      host_.send link_ 4 packet
      submitted = true
    finally:
      if not submitted: close
    return receipt

  finish-indication_ error -> none:
    critical-do --no-respect-deadline:
      if indication-timer_: indication-timer_.cancel
      indication-timer_ = null
      receipt := indication_
      indication_ = null
      change-indication_ = false
      if receipt:
        receipt.serving-task_ = null
        if error: receipt.completed_.set error --exception
        else: receipt.completed_.set true

  /** Closes session state and aborts its link; safe to repeat. */
  close -> none:
    critical-do --no-respect-deadline:
      if closed_: return
      closed_ = true
      // A provider-owned security hook can fail. Finish local state and link
      // cleanup before propagating that error; closed_ makes retry a no-op.
      error := catch:
        if pairing_: pairing_.close
      finish-indication_ "GATT_SERVER_CLOSED"
      if handling_ and serving-task_ and serving-task_ != Task.current:
        serving-task_.cancel
      if parameter-timer_:
        parameter-timer_.cancel
        parameter-timer_ = null
      if parameter-status_ == "pending": parameter-status_ = "closed"
      session_.close
      if link_.connected: host_.abort link_ --error="GATT_SERVER_CLOSED"
      if error: throw error

  check-open_ -> none:
    if closed_: throw "GATT_SERVER_CLOSED"

  receive-loop_ [read] [validate] [written] -> none:
    while true:
      packet := link_.receive --owner=this
      // Decode a verdict only while its request is outstanding. Later replies
      // are unsolicited; the generic policy discards recognized responses
      // without interpreting their bodies (Core 6.3, Vol 3 Part A, section 4).
      if packet.channel == 5 and parameter-status_ == "pending":
        result := signaling.parameter-response packet.payload 1
        if result != null:
          parameter-status_ = result == 0 ? "accepted" : "rejected"
          if parameter-timer_: parameter-timer_.cancel
          parameter-timer_ = null
          continue
      if packet.channel == 5:
        host_.handle-signaling link_ packet.payload
        continue
      if packet.channel == 6:
        if pairing_:
          pairing_.receive packet.payload
          continue
        response := signaling.security-response packet.payload
        if response: host_.send link_ 6 response
        continue
      if packet.channel != 4: throw "ATT_UNHANDLED_L2CAP_CHANNEL"
      if not packet.payload.is-empty and packet.payload[0] == 0x1e:
        if packet.payload.size != 1: throw "ATT_INVALID_CONFIRMATION"
        // A confirmation has no handle; it belongs to the sole pending receipt.
        // Its wire deadline ends here. Durable change-state clearing has its
        // own bounded storage deadline and must not race the old wire timer.
        if indication-timer_: indication-timer_.cancel
        indication-timer_ = null
        if indication_ and change-indication_: session_.confirm-service-changed
        finish-indication_ null
        continue
      read-handler := (: | request/attributes.ReadRequest |
        handling_ = true
        try:
          read.call request
        finally:
          handling_ = false)
      validate-handler := (: | request/attributes.WriteRequest |
        handling_ = true
        try:
          validate.call request
        finally:
          handling_ = false)
      with-timeout --ms=10_000:
        response := session_.request packet.payload read-handler validate-handler
        if response:
          host_.send link_ 4 response
          session_.response-sent
        session_.writes-do: | handle/int value/ByteArray |
          handling_ = true
          try:
            written.call handle value
          finally:
            handling_ = false
