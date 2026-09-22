// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .bond show Candidate
import .central show Central Link
import .encryption as encryption
import .security-owner show Owner
import .signaling as signaling

/**
Attempts SC encryption on a fresh connection using a trusted stored candidate.

The caller authenticates storage and selects the record. Both identities must
  match this connection's stable address or resolve its RPA. Resolution selects
  a candidate; it is not authentication. Only a successful controller encryption
  result makes this owner grant encrypted/authenticated attribute access. With
  --require-authentication, a Just Works record is rejected before key installation.

Attach to the ATT client/server as its pairing owner, then call run. Peripheral
  construction installs the key; construct it in Central.on-connected when an
  immediate LTK request is possible. That hook must use preloaded records.
  This class does not retry pairing or grant unencrypted fallback. It does not
  mark a stored candidate as committed or prove prior distribution delivery.
*/
class Resume implements Owner:
  host_/Central
  link_/Link
  key_/ByteArray? := ?
  authenticated_/bool
  used_/bool := false
  ready_/bool := false
  closed_/bool := false

  constructor .host_ .link_ candidate/Candidate --local-address/ByteArray --require-authentication/bool=false:
    if not (host_.owns-link link_): throw "HCI_INVALID_LINK"
    if require-authentication and not candidate.authenticated: throw "BLE_BOND_INSUFFICIENT_AUTHENTICATION"
    if local-address.size != 6: throw "INVALID_ARGUMENT"
    if link_.encryption-change != null: throw "BLE_BOND_REQUIRES_FRESH_LINK"
    selected := link_.local-random-address
    if selected and selected != local-address: throw "SMP_WRONG_LOCAL_ADDRESS"
    if not (candidate.local.matches local-address --address-type=(selected ? 1 : 0)):
      throw "BLE_BOND_WRONG_LOCAL_IDENTITY"
    if not (candidate.peer.matches link_.info.address --address-type=link_.info.address-type):
      throw "BLE_BOND_WRONG_PEER_IDENTITY"
    key_ = candidate.key
    authenticated_ = candidate.authenticated
    if link_.info.role == 1:
      host_.set-encryption-key link_ key_
      key_ = null

  matches host/Central link/Link -> bool: return host == host_ and link == link_
  paired -> bool: return ready_ and not closed_ and link_.connected
  encrypted -> bool: return paired and link_.encrypted
  authenticated -> bool: return encrypted and authenticated_

  /** Attempts encryption once; failure/cancellation aborts this link. */
  run --timeout/Duration=(Duration --s=30) -> none:
    if used_ or closed_: throw "BLE_BOND_RESUME_INVALID_STATE"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    used_ = true
    succeeded := false
    try:
      with-timeout timeout:
        if link_.info.role == 0:
          host_.encrypt link_ key_ --timeout=timeout
        else:
          change := link_.wait-encryption-change
          if change.status != 0: throw (encryption.Error change.status)
          if not change.enabled: throw "HCI_ENCRYPTION_NOT_ENABLED"
        if closed_: throw "BLE_BOND_RESUME_CLOSED"
        link_.require-encryption
        ready_ = true
      succeeded = true
    finally:
      key_ = null
      if not succeeded: close

  /**
  Rejects re-pairing; replacement requires an explicit provider decision.

  Ignores Security Requests while central encryption setup is in progress, as
    required by Core 6.3, Vol 3, Part H, 2.4.6. Does not initiate a second setup
    or promote the bond's authentication level from peer-requested flags.
  */
  receive bytes/ByteArray -> none:
    if closed_: throw "BLE_BOND_RESUME_CLOSED"
    if link_.info.role == 0 and used_ and not ready_ and
        bytes.size == 2 and bytes[0] == 0x0b:
      return
    response := signaling.security-response bytes
    if response: host_.send link_ 6 response

  /** Ends this security lifetime and releases installed keys through link abort. */
  close -> none:
    if closed_: return
    closed_ = true
    ready_ = false
    key_ = null
    if link_.connected: host_.abort link_ --error="BLE_BOND_RESUME_CLOSED"
