// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import io

/**
Tracks a bounded controller-to-host ACL window across connection lifetimes.

Does not enable flow control or send commands. The caller records connection
  events in transport order and releases packets only after consumption or
  admission into another bounded stage. Unknown handles fail closed; early ACL
  delivery before connection registration requires separate integration policy.
  Methods do not wait. Close deterministically; GC never returns protocol credits.
*/
class ReceiveCredits:
  capacity/int
  outstanding_/int := 0
  accounts_/Map := {:}
  receipts_/List := []
  closed_/bool := false

  constructor .capacity:
    if not 1 <= capacity <= 32: throw "INVALID_ARGUMENT"

  /** Returns the number of active packets still charged to the window. */
  outstanding -> int: return outstanding_

  /** Registers a fresh lifetime; duplicate live handles are an error. */
  connected handle/int -> none:
    check-open_
    if not 0 <= handle <= 0x0eff: throw "INVALID_ARGUMENT"
    if accounts_.contains handle: throw "HCI_RX_DUPLICATE_HANDLE"
    if accounts_.size >= 16: throw "HCI_RX_CONNECTION_LIMIT"
    accounts_[handle] = Account_ handle

  /** Charges one owned H4 ACL packet without copying its payload. */
  received packet/ByteArray -> Receipt:
    check-open_
    if packet.size < 5 or packet[0] != 2 or
        (io.LITTLE-ENDIAN.uint16 packet 3) != packet.size - 5:
      throw "HCI_RX_INVALID_PACKET"
    handle := (io.LITTLE-ENDIAN.uint16 packet 1) & 0x0fff
    account/Account_? := accounts_.get handle
    if not account: throw "HCI_RX_UNKNOWN_HANDLE"
    if find packet: throw "HCI_RX_DUPLICATE_PACKET"
    if outstanding_ == capacity: throw "HCI_RX_WINDOW_EXCEEDED"
    receipt := Receipt.create_ this account packet
    receipts_.add receipt
    outstanding_++
    account.outstanding++
    return receipt

  /** Finds a currently charged packet by identity, not byte equality. */
  find packet/ByteArray -> Receipt?:
    receipts_.do: | receipt/Receipt |
      if identical receipt.packet_ packet: return receipt
    return null

  /** Invalidates outstanding receipts before this numeric handle can be reused. */
  disconnected handle/int -> none:
    check-open_
    account/Account_? := accounts_.get handle
    if not account: throw "HCI_RX_UNKNOWN_HANDLE"
    accounts_.remove handle
    account.active = false
    outstanding_ -= account.outstanding
    account.outstanding = 0
    size := receipts_.size
    size.repeat: | i/int |
      index := size - 1 - i
      // Iterate a fixed original range; removals only affect higher indices.
      receipt/Receipt := receipts_[index]
      if identical receipt.account_ account:
        receipt.packet_ = null
        receipts_.remove --at=index

  /** Invalidates all receipts and drops packet references without sending credits. */
  close -> none:
    // Repeated calls also finish any cleanup interrupted by allocation failure.
    closed_ = true
    accounts_.do --values: | account/Account_ | account.active = false
    receipts_.do: | receipt/Receipt | receipt.packet_ = null
    accounts_.clear
    receipts_.clear
    outstanding_ = 0

  finish_ receipt/Receipt --submitted/bool -> none:
    if receipt.finished_: throw "HCI_RX_RECEIPT_FINISHED"
    active := receipt.can-submit
    if active and not submitted: throw "HCI_RX_UNRETURNED_CREDIT"
    receipt.finished_ = true
    receipt.packet_ = null
    if active:
      receipts_.remove receipt
      receipt.account_.outstanding--
      outstanding_--

  check-open_ -> none:
    if closed_: throw "HCI_RX_CREDITS_CLOSED"

/** A single packet's credit, bound to its original connection lifetime. */
class Receipt:
  owner_/ReceiveCredits
  account_/Account_
  packet_/ByteArray? := ?
  finished_/bool := false

  constructor.create_ .owner_ .account_ packet/ByteArray:
    packet_ = packet

  /** Tests permission immediately before transport acceptance, without waiting. */
  can-submit -> bool: return not finished_ and not owner_.closed_ and account_.active

  /** Builds one Host Number Of Completed Packets command, including H4 framing. */
  command -> ByteArray:
    if not can-submit: throw "HCI_RX_STALE_RECEIPT"
    result := #[1, 0x35, 0x0c, 5, 1, 0, 0, 1, 0]
    io.LITTLE-ENDIAN.put-uint16 result 5 account_.handle
    return result

  /**
  Settles a guarded transport submission exactly once.

  Call with its actual $submitted result. A disconnect may retire the account
    between acceptance and settlement; settling then cannot debit a new lifetime.
    A live credit that was not submitted remains outstanding and raises an error.
  */
  finish --submitted/bool -> none: owner_.finish_ this --submitted=submitted

class Account_:
  handle/int
  active/bool := true
  outstanding/int := 0

  constructor .handle:
