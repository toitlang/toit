// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .smp-identity as identity
import .smp-legacy as legacy
import .security-state show SecurityState
import .smp-features show PairingError

/**
The key distribution phase that follows a bonding pairing.

$Exchange orders the PDUs both sides send once the link is encrypted: the
  legacy long term keys (`smp-legacy`) and the identities (`smp-identity`),
  peripheral first, in the directions the pairing negotiated. $Exchange.start
  and $Exchange.receive return the PDUs to send next; $Exchange.peer-identity
  and $Exchange.peer-legacy-key expose what the peer distributed. The
  pairing owner (`security.Pairing`) drives it and sends the packets.
*/

/**
Orders a negotiated identity and key exchange between the two sides.

The peripheral issues its identity first. The central waits for that identity
  before issuing its own, unless no peripheral identity was negotiated. Legacy
  pairing distributes long term keys (Encryption Information, Central
  Identification) before identities, in the same responder-first order. Methods
  return ordered PDUs for the connection owner to submit. They never report
  delivery, bond completion or persistence. The owner supplies the negotiated
  directions, enforces the procedure deadline and sends each returned list once.
*/
class Exchange:
  security_/SecurityState
  initiator_/bool
  local_/identity.Identity? := ?
  receiver_/identity.Receiver? := ?
  local-key_/legacy.LegacyKey? := ?
  key-receiver_/legacy.LegacyKeyReceiver? := ?
  started_/bool := false
  closed_/bool := false
  issued_/bool := false

  constructor .security_ --initiator/bool --local/identity.Identity?=null --receive-identity/bool
      --local-key/legacy.LegacyKey?=null --receive-key/bool=false:
    initiator_ = initiator
    local_ = local
    receiver_ = receive-identity ? (identity.Receiver security_) : null
    local-key_ = local-key
    key-receiver_ = receive-key ? (legacy.LegacyKeyReceiver security_) : null

  /** Starts the encrypted phase and returns any immediately eligible local PDUs. */
  start -> List:
    if started_ or closed_: throw "SMP_DISTRIBUTION_INVALID_STATE"
    started_ = true
    succeeded := false
    try:
      check-encryption_
      result := (not initiator_ or not expects-peer_) ? issue_ : []
      succeeded = true
      return result
    finally:
      if not succeeded: close

  /** Accepts one negotiated peer PDU and returns newly eligible local PDUs. */
  receive packet/ByteArray -> List:
    check-active_
    succeeded := false
    try:
      if key-receiver_ and not key-receiver_.key:
        key-receiver_.receive packet
      else:
        if not receiver_: throw (PairingError 0x0a)
        receiver_.receive packet
      result := initiator_ and peer-complete_ ? issue_ : []
      succeeded = true
      return result
    finally:
      if not succeeded: close

  /** Returns complete candidate peer data, never a bonded/authenticated assertion. */
  peer-identity -> identity.Identity?:
    check-active_
    return receiver_ and receiver_.identity

  /** Returns the peer's distributed legacy key, or null while pending or not negotiated. */
  peer-legacy-key -> legacy.LegacyKey?:
    check-active_
    return key-receiver_ and key-receiver_.key

  /** Reports whether local packets have been issued to the owner, not delivered. */
  local-identity-issued -> bool:
    check-active_
    return issued_

  expects-peer_ -> bool: return receiver_ != null or key-receiver_ != null

  peer-complete_ -> bool:
    if key-receiver_ and not key-receiver_.key: return false
    if receiver_ and not receiver_.identity: return false
    return true

  issue_ -> List:
    if issued_: return []
    packets := []
    if local-key_: packets.add-all (local-key_.packets security_)
    if local_: packets.add-all (local_.packets security_)
    if not packets.is-empty: issued_ = true
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
    if key-receiver_: key-receiver_.close
    key-receiver_ = null
    local-key_ = null
