// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .hci as hci

/**
ACL data between the link owner and the controller.

$ControllerCredits is the controller-wide transmit packet budget with one
  $Credits account per connection lifetime; $completed-do feeds it the
  controller's Number Of Completed Packets events. $fragments-do splits one
  L2CAP PDU into ACL packets for sending and $Reassembler rebuilds a $Packet
  from the received ones. The link owner (central) and each link use these;
  nothing above the link sees ACL fragments.
*/

/** A complete basic L2CAP PDU payload in managed storage. */
class Packet:
  channel/int
  payload/ByteArray

  constructor .channel .payload:

/**
A shared controller ACL packet budget with bounded per-connection accounts.

Eligible waiters are granted in arrival order. An account at its own quota does
  not block another account with capacity. One sender may wait per account;
  the link's whole-PDU send mutex provides that serialization.
*/
monitor ControllerCredits:
  capacity_/int
  account-limit_/int
  accounts_/int := 0
  outstanding_/int := 0
  waiting_/List := []

  constructor .capacity_ --account-limit/int=1:
    if capacity_ < 1 or not 1 <= account-limit <= 16: throw "INVALID_ARGUMENT"
    account-limit_ = account-limit

  /** Returns the number of packets currently charged to all accounts. */
  outstanding -> int: return outstanding_

  /** Returns the number of accounts currently waiting for packet capacity. */
  waiting-count -> int: return waiting_.size

  attach account/Credits -> none:
    if account.pool_ != this or account.registered_ or account.error_: throw "INVALID_ARGUMENT"
    if not 1 <= account.quota_ <= capacity_: throw "INVALID_ARGUMENT"
    if accounts_ == account-limit_: throw "HCI_ACL_ACCOUNT_LIMIT"
    accounts_++
    account.registered_ = true

  take account/Credits -> none:
    if account.pool_ != this: throw "INVALID_ARGUMENT"
    if account.error_: throw account.error_
    if account.waiting_: throw "HCI_ACL_CREDIT_BUSY"
    // Fast path: nobody queued ahead and capacity at hand, so no waiter
    // bookkeeping. Arrival order is preserved because the queue is empty.
    if waiting_.is-empty and outstanding_ < capacity_ and account.outstanding_ < account.quota_:
      account.outstanding_++
      outstanding_++
      return
    try:
      // Protect publication too: entering cleanup scope can require stack space.
      waiting_.add account
      account.waiting_ = true
      await: account.error_ or (eligible_ account)
      if account.error_: throw account.error_
      account.outstanding_++
      outstanding_++
    finally:
      waiting_.remove account
      account.waiting_ = false

  eligible_ account/Credits -> bool:
    if outstanding_ == capacity_: return false
    waiting_.do: | candidate/Credits |
      if not candidate.error_ and candidate.outstanding_ < candidate.quota_:
        return candidate == account
    return false

  complete account/Credits count/int -> none:
    if account.pool_ != this: throw "INVALID_ARGUMENT"
    if not account.registered_: throw account.error_
    if not 0 <= count <= account.outstanding_: throw "HCI_INVALID_ACL_CREDITS"
    account.outstanding_ -= count
    outstanding_ -= count

  drain account/Credits -> none:
    if account.pool_ != this: throw "INVALID_ARGUMENT"
    await: account.error_ or account.outstanding_ == 0
    if account.error_: throw account.error_

  stop account/Credits error -> none:
    if account.pool_ != this or not error: throw "INVALID_ARGUMENT"
    if account.error_: return
    account.error_ = error
    waiting_.remove account

  release account/Credits error -> none:
    if account.pool_ != this or not error: throw "INVALID_ARGUMENT"
    if not account.registered_: return
    account.error_ = account.error_ or error
    outstanding_ -= account.outstanding_
    account.outstanding_ = 0
    accounts_--
    account.registered_ = false
    waiting_.remove account

/** One connection lifetime's quota and outstanding controller packet count. */
class Credits:
  pool_/ControllerCredits
  quota_/int
  outstanding_/int := 0
  error_ := null
  waiting_/bool := false
  registered_/bool := false

  constructor .quota_ --pool/ControllerCredits?=null:
    pool_ = pool or (ControllerCredits quota_)
    pool_.attach this

  take -> none: pool_.take this

  // Counts reusable controller buffers, not peer acknowledgments. Core Vol 4
  // Part E 4.1 permits completion when data moves to other controller storage.
  // Bond-key distribution must not infer delivery from returned credits.
  complete count/int -> none: pool_.complete this count

  /** Waits for returned controller credits, not an application acknowledgement. */
  drain -> none: pool_.drain this

  /** Stops senders while retaining credits until completion or disconnection. */
  stop error -> none: pool_.stop this error

  /**
  Releases this account on Disconnection Complete or controller shutdown.

  Disconnection releases outstanding buffers without a Completed Packets event.
    Old accounts cannot spend a replacement link's credits, even if the
    controller reuses its numeric handle.
  */
  fail error -> none:
    // The controller flushes the link's buffers on disconnect: Core 6.3 Vol 4
    // Part E 4.3.
    if not error: throw "INVALID_ARGUMENT"
    pool_.release this error

/** A bounded reliable PDU queue; overflow is explicit, never a silent drop. */
monitor Inbox:
  queue_/List := []
  error_ := null
  high-water/int := 0

  add packet/Packet -> none:
    if error_: throw error_
    if queue_.size >= 32: throw "L2CAP_QUEUE_OVERFLOW"
    queue_.add packet
    high-water = max high-water queue_.size

  take -> Packet:
    await: error_ or not queue_.is-empty
    if error_: throw error_
    return queue_.remove --at=0

  fail error -> none:
    if error_: return
    error_ = error
    queue_.clear

/** Decodes a Number Of Completed Packets event's per-handle counts; false for other events. */
completed-do packet/ByteArray [completed] -> bool:
  // Core 6.3 Vol 4 Part E, 7.7.19.
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x13: return false
  if packet.size < 4 or packet.size != 4 + packet[3] * 4:
    throw "HCI_MALFORMED_ACL_CREDITS"
  packet[3].repeat: | index/int |
    if (io.LITTLE-ENDIAN.uint16 packet (4 + 4 * index)) > 0x0eff:
      throw "HCI_MALFORMED_ACL_CREDITS"
  packet[3].repeat: | index/int |
    offset := 4 + 4 * index
    completed.call (io.LITTLE-ENDIAN.uint16 packet offset)
        io.LITTLE-ENDIAN.uint16 packet (offset + 2)
  return true

/**
Fragments one basic L2CAP PDU into host-to-controller LE ACL packets.

Calls the scoped $send block in wire order. The caller must serialize whole PDUs
  on a connection and acquire one controller credit per fragment before sending.
  All emitted arrays are owned managed storage. The $limit is the controller's
  ACL data length, excluding its HCI header.
*/
fragments-do handle/int channel/int payload/ByteArray --limit/int [send] -> none:
  // ACL packet format and fragmentation flags: Core 6.3 Vol 4 Part E, 5.4.2.
  if not 0 <= handle <= 0x0eff or not 1 <= channel <= 0xffff or
      not 1 <= limit <= 1024 or payload.size > 1024:
    throw "INVALID_ARGUMENT"
  if payload.size + 4 <= limit:
    // One fragment: frame the payload directly instead of building the
    // L2CAP PDU first and copying it again.
    packet := ByteArray (9 + payload.size)
    packet[0] = 2
    io.LITTLE-ENDIAN.put-uint16 packet 1 handle
    io.LITTLE-ENDIAN.put-uint16 packet 3 (4 + payload.size)
    io.LITTLE-ENDIAN.put-uint16 packet 5 payload.size
    io.LITTLE-ENDIAN.put-uint16 packet 7 channel
    packet.replace 9 payload
    send.call packet
    return
  pdu := ByteArray (4 + payload.size)
  io.LITTLE-ENDIAN.put-uint16 pdu 0 payload.size
  io.LITTLE-ENDIAN.put-uint16 pdu 2 channel
  pdu.replace 4 payload
  offset := 0
  while offset < pdu.size:
    length := min limit (pdu.size - offset)
    packet := ByteArray (5 + length)
    packet[0] = 2
    // Host-to-controller LE starts use PB=0; continuations use PB=1.
    io.LITTLE-ENDIAN.put-uint16 packet 1 (handle | (offset == 0 ? 0 : 0x1000))
    io.LITTLE-ENDIAN.put-uint16 packet 3 length
    packet.replace 5 pdu[offset..offset + length]
    send.call packet
    offset += length

/**
Reassembles one connection's controller-to-host LE ACL packets.

Limits allocation using the announced L2CAP length, even when its header spans
  fragments. A malformed sequence resets partial storage and throws an explicit
  error. The owner must report the resulting loss of channel reliability, as
  the channel has no way to resynchronize. Use a fresh instance for each
  connection lifetime.
*/
class Reassembler:
  // Reassembly and the loss of reliability on error: Core 6.3 Vol 3 Part A, 7.2.2.
  handle_/int
  limit_/int
  header_/ByteArray ::= ByteArray 4
  filled_/int := 0
  buffer_/ByteArray? := null
  active_/bool := false

  constructor .handle_ --limit/int=64:
    if not 0 <= handle_ <= 0x0eff or not 0 <= limit <= 1024:
      throw "INVALID_ARGUMENT"
    limit_ = limit

  /** Consumes one ACL packet, returning a PDU only when it is complete. */
  accept packet/ByteArray -> Packet?:
    result/Packet? := null
    error := catch: result = accept_ packet
    if error:
      clear
      throw error
    return result

  /** Releases partial data when the connection ends. */
  clear -> none:
    active_ = false
    filled_ = 0
    buffer_ = null

  accept_ packet/ByteArray -> Packet?:
    hci.validate-packet packet
    if packet[0] != 2: throw "HCI_EXPECTED_ACL"
    flags := io.LITTLE-ENDIAN.uint16 packet 1
    if flags & 0x0fff != handle_ or flags & 0xc000 != 0:
      throw "HCI_INVALID_ACL_HANDLE"
    boundary := (flags >> 12) & 3
    if boundary == 2:
      if active_: throw "L2CAP_INTERRUPTED_PDU"
      active_ = true
    else if boundary == 1:
      if not active_: throw "L2CAP_ORPHAN_FRAGMENT"
    else:
      throw "HCI_INVALID_ACL_BOUNDARY"
    offset := 5
    if filled_ < 4:
      count := min (4 - filled_) (packet.size - offset)
      header_.replace filled_ packet[offset..offset + count]
      filled_ += count
      offset += count
      if filled_ < 4: return null
      length := io.LITTLE-ENDIAN.uint16 header_ 0
      if length > limit_: throw "L2CAP_PDU_TOO_LARGE"
      if (io.LITTLE-ENDIAN.uint16 header_ 2) == 0: throw "L2CAP_INVALID_CHANNEL"
      buffer_ = ByteArray length
    buffer := buffer_
    count := packet.size - offset
    if filled_ - 4 + count > buffer.size: throw "L2CAP_INVALID_LENGTH"
    buffer.replace (filled_ - 4) packet[offset..]
    filled_ += count
    if filled_ - 4 != buffer.size: return null
    result := Packet (io.LITTLE-ENDIAN.uint16 header_ 2) buffer
    clear
    return result
