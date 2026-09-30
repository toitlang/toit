// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .security-state show SecurityState
import .smp-features show PairingError
import .connection as connection
import .privacy as privacy

/**
The identity a device distributes after pairing: its IRK and identity address.

$Identity holds one such identity, either the local one to distribute or a
  peer's as received, and matches connection addresses against it, resolving
  private addresses with the IRK. $Identity.packets encodes it as the two
  Identity Information and Identity Address Information PDUs; $Receiver
  collects the peer's pair. The distribution exchange (`smp-distribution`)
  orders these on behalf of the pairing owner; bond records (`bond`) store
  the identities.

IRKs use crypto most-significant-first order; six-byte addresses use HCI order.
  This bounded codec does not negotiate distribution, send packets, persist a
  bond, or report baseband acknowledgment of outgoing keys. The connection owner
  must enforce peripheral-before-central distribution and its procedure deadline.
*/

/** An owned peer identity, which is not itself evidence of authenticated pairing. */
class Identity:
  irk_/ByteArray
  address_/ByteArray
  address-type/int

  constructor irk/ByteArray address/ByteArray .address-type:
    if irk.size != 16 or address.size != 6 or not 0 <= address-type <= 1:
      throw "INVALID_ARGUMENT"
    if address-type == 1:
      if address[5] & 0xc0 != 0xc0: throw "INVALID_ARGUMENT"
      connection.random-address address
    irk_ = irk.copy
    address_ = address.copy

  /** Returns an owned IRK in crypto order; zero denotes no valid RPA capability. */
  irk -> ByteArray: return irk_.copy
  /** Returns an owned public or static identity address in HCI order. */
  address -> ByteArray: return address_.copy

  /** Tests whether the distributed IRK is nonzero. */
  has-resolving-key -> bool:
    nonzero := 0
    irk_.do: nonzero |= it
    return nonzero != 0

  /**
  Matches the stable address or resolves an RPA, without authenticating a peer.

  Addresses use HCI byte order. Controller-resolved address types 2 and 3 are
    not interpreted here; they return false. Invalid sizes/types throw.
  */
  matches address/ByteArray --address-type/int -> bool:
    if address.size != 6 or not 0 <= address-type <= 3: throw "INVALID_ARGUMENT"
    if address-type == this.address-type and address == address_: return true
    return has-resolving-key and (privacy.resolves irk_ address address-type)

  /** Encodes the ordered pair only while this connection has its new encryption key. */
  packets security/SecurityState -> List:
    require-encryption_ security
    return [#[8] + (ByteArray 16: irk_[15 - it]), #[9, address-type] + address_]

/** Collects one negotiated peer identity, withholding partial or failed results. */
class Receiver:
  security_/SecurityState
  pending_/ByteArray? := null
  identity_/Identity? := null
  closed_/bool := false

  constructor .security_:

  /** Accepts Identity Information followed by Identity Address Information. */
  receive packet/ByteArray -> none:
    if closed_: throw "SMP_IDENTITY_CLOSED"
    succeeded := false
    try:
      require-encryption_ security_
      if identity_: throw (PairingError 0x0a)
      if not pending_:
        if packet.size != 17 or packet[0] != 8: throw (PairingError 0x0a)
        pending_ = ByteArray 16: packet[16 - it]
      else:
        if packet.size != 8 or packet[0] != 9: throw (PairingError 0x0a)
        error := catch: identity_ = Identity pending_ packet[2..] packet[1]
        if error == "INVALID_ARGUMENT": throw (PairingError 0x0a)
        if error: throw error
        pending_ = null
      succeeded = true
    finally:
      if not succeeded: close

  /** Returns the complete identity while encryption remains live, or null while pending. */
  identity -> Identity?:
    if closed_: throw "SMP_IDENTITY_CLOSED"
    error := catch: require-encryption_ security_
    if error:
      close
      throw error
    return identity_

  /** Discards references; this does not promise erasure of copies made by compacting GC. */
  close -> none:
    closed_ = true
    pending_ = null
    identity_ = null

require-encryption_ security/SecurityState -> none:
  if not security.paired or not security.encrypted: throw "SMP_IDENTITY_NOT_ENCRYPTED"
