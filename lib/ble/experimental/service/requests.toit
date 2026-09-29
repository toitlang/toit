// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import ..attribute-server as attributes
import .api as api

READ ::= api.READ
VALIDATE-WRITE ::= api.VALIDATE-WRITE
WRITTEN ::= api.WRITTEN

/**
A single pending application request, pulled by one service client.

The ATT serving task waits here while HCI tasks continue. No request objects or
  blocks cross RPC: a record contains token, kind, handle, opcode, deadline, and
  an owned value. Replies contain ATT error code and an optional read value.
  A token is valid only until its originating handler returns or is canceled.
*/
class Requests:
  mailbox_ ::= Mailbox_
  value-limit_/int
  written-timeout/Duration := Duration --s=1

  constructor --value-limit/int=20:
    if not 1 <= value-limit <= 512: throw "INVALID_ARGUMENT"
    value-limit_ = value-limit

  /** Forwards a scoped read and applies the remote reply within its lifetime. */
  read request/attributes.ReadRequest -> none:
    response := exchange READ request.handle request.opcode #[] request.deadline
    if response[0] != 0: request.reject response[0]
    else: request.reply response[1]

  /** Forwards pre-commit validation, preserving the proposed value. */
  validate request/attributes.WriteRequest -> none:
    response := exchange VALIDATE-WRITE request.handle request.opcode request.value request.deadline
    if response[0] != 0: request.reject response[0]
    else: request.accept

  /** Waits for an accepted-write hook within the configured handler budget. */
  written handle/int value/ByteArray -> none:
    response := exchange WRITTEN handle 0 value (Time.monotonic-us + written-timeout.in-us)
    if response[0] != 0: throw "GATT_REMOTE_HANDLER_FAILED"

  /** Exchanges one bounded record; overlapping producers are rejected. */
  exchange kind/int handle/int opcode/int value/ByteArray deadline/int -> List:
    if kind != READ and kind != VALIDATE-WRITE and kind != WRITTEN: throw "INVALID_ARGUMENT"
    if not 1 <= handle <= 0xffff or not 0 <= opcode <= 255 or value.size > value-limit_:
      throw "INVALID_ARGUMENT"
    if deadline <= Time.monotonic-us: throw "GATT_REQUEST_EXPIRED"
    token := mailbox_.offer kind handle opcode value deadline
    try:
      return with-timeout (Duration --us=(deadline - Time.monotonic-us)):
        mailbox_.response token
    finally:
      critical-do --no-respect-deadline: mailbox_.discard token

  /** Pulls the next record once; a second concurrent pull is rejected. */
  next -> List: return mailbox_.next

  /** Supplies a read value, write acceptance, hook completion, or ATT error. */
  reply token/int --error/int=0 --value/ByteArray=#[] -> none:
    if not 0 <= error <= 255 or value.size > value-limit_: throw "INVALID_ARGUMENT"
    mailbox_.reply token error value

  /** Waits until the session ends, for client handler cancellation. */
  wait-closed -> string: return mailbox_.wait-closed

  /** Wakes all waiters and invalidates any outstanding token. */
  close --error/string="GATT_REQUESTS_CLOSED" -> none:
    critical-do --no-respect-deadline: mailbox_.close error

monitor Mailbox_:
  packet_/List? := null
  response_/List? := null
  sequence_/int := 0
  delivered_/bool := false
  pulling_/bool := false
  closed_/bool := false
  error_/string := "GATT_REQUESTS_CLOSED"

  offer kind/int handle/int opcode/int value/ByteArray deadline/int -> int:
    check-open_
    if packet_: throw "GATT_REQUEST_BUSY"
    sequence_++
    packet_ = [sequence_, kind, handle, opcode, deadline, value.copy]
    delivered_ = false
    response_ = null
    return sequence_

  next -> List:
    check-open_
    if pulling_: throw "GATT_REQUEST_PULL_BUSY"
    pulling_ = true
    try:
      await: closed_ or (packet_ and not delivered_)
      check-open_
      if Time.monotonic-us >= packet_[4]: throw "GATT_REQUEST_EXPIRED"
      result := List.from packet_
      empty := #[]
      // A failure before this point leaves the offer available for another pull.
      delivered_ = true
      // Transfer the owned value; keep private metadata for reply validation.
      packet_[5] = empty
      return result
    finally:
      pulling_ = false

  reply token/int error/int value/ByteArray -> none:
    check-open_
    if not packet_ or token != packet_[0] or Time.monotonic-us >= packet_[4]:
      throw "GATT_REQUEST_EXPIRED"
    if not delivered_: throw "GATT_REQUEST_NOT_DELIVERED"
    if response_: throw "GATT_ALREADY_REPLIED"
    if (error != 0 or packet_[1] != READ) and not value.is-empty:
      throw "INVALID_ARGUMENT"
    response_ = [error, value.copy]

  response token/int -> List:
    await: closed_ or response_
    check-open_
    if not packet_ or packet_[0] != token: throw "GATT_REQUEST_EXPIRED"
    return response_

  discard token/int -> none:
    if packet_ and packet_[0] == token:
      packet_ = null
      response_ = null

  close error/string -> none:
    if closed_: return
    error_ = error
    closed_ = true
    packet_ = null
    response_ = null

  wait-closed -> string:
    await: closed_
    return error_

  check-open_ -> none:
    if closed_: throw error_
