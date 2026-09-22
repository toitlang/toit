// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .smp-identity as identity
import .security-state show SecurityState
import .smp-features show PairingError

/**
Orders a negotiated SC identity exchange (Core 6.3 Vol 3 Part H 3.6.1).

The peripheral issues its identity first. The central waits for that identity
  before issuing its own, unless no peripheral identity was negotiated. Methods
  return ordered PDUs for the connection owner to submit. They never report
  delivery, bond completion or persistence. The owner supplies the negotiated
  directions, enforces the procedure deadline and sends each returned list once.
*/
class Exchange:
  security_/SecurityState
  initiator_/bool
  local_/identity.Identity? := ?
  receiver_/identity.Receiver? := ?
  started_/bool := false
  closed_/bool := false
  issued_/bool := false

  constructor .security_ --initiator/bool --local/identity.Identity?=null --receive-identity/bool:
    initiator_ = initiator
    local_ = local
    receiver_ = receive-identity ? (identity.Receiver security_) : null

  /** Starts the encrypted phase and returns any immediately eligible local PDUs. */
  start -> List:
    if started_ or closed_: throw "SMP_DISTRIBUTION_INVALID_STATE"
    started_ = true
    succeeded := false
    try:
      check-encryption_
      result := (not initiator_ or not receiver_) ? issue_ : []
      succeeded = true
      return result
    finally:
      if not succeeded: close

  /** Accepts one negotiated peer PDU and returns newly eligible local PDUs. */
  receive packet/ByteArray -> List:
    check-active_
    succeeded := false
    try:
      if not receiver_: throw (PairingError 0x0a)
      receiver_.receive packet
      result := initiator_ and receiver_.identity ? issue_ : []
      succeeded = true
      return result
    finally:
      if not succeeded: close

  /** Returns complete candidate peer data, never a bonded/authenticated assertion. */
  peer-identity -> identity.Identity?:
    check-active_
    return receiver_ and receiver_.identity

  /** Reports whether local packets have been issued to the owner, not delivered. */
  local-identity-issued -> bool:
    check-active_
    return issued_

  issue_ -> List:
    if issued_ or not local_: return []
    packets := local_.packets security_
    issued_ = true
    return packets

  check-active_ -> none:
    if not started_ or closed_: throw "SMP_DISTRIBUTION_INVALID_STATE"
    check-encryption_

  check-encryption_ -> none:
    if not security_.paired or not security_.encrypted:
      close
      throw "SMP_IDENTITY_NOT_ENCRYPTED"

  /** Discards candidate references when the owner cancels, times out, or closes. */
  close -> none:
    closed_ = true
    if receiver_: receiver_.close
    receiver_ = null
    local_ = null
