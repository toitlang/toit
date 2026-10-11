// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

import .bond show Candidate
import .central show Central Link
import .encryption as encryption
import .smp-legacy show LegacyKey
import .security-owner show Owner
import .timeouts as timeouts
import .signaling as signaling

/**
Resumption of a stored bond on a new connection.

$Resume is the security $Owner for a link whose peer is already bonded: it
  takes the stored $Candidate, installs its key and encrypts the link
  ($Resume.run) instead of pairing again, and answers a peer's Security
  Request with that key ($Resume.receive). `bond-registry` creates one per
  admitted connection from its bond table; the owner is attached to the
  link's ATT client or GATT server like a fresh `security.Pairing`.
*/

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
  legacy_/LegacyKey? := ?
  authenticated_/bool
  used_/bool := false
  joined_/bool := false
  ready_/bool := false
  closed_/bool := false
  worker_/Task? := null
  result_/monitor.Latch ::= monitor.Latch

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
    authenticated_ = candidate.authenticated
    if candidate.legacy:
      // A legacy bond resumes with the key the peer distributed (central) or
      // the one this side distributed (peripheral); the STK is not kept.
      key_ = null
      legacy_ = link_.info.role == 0 ? candidate.peer-legacy : candidate.local-legacy
      if not legacy_: throw "BLE_BOND_NO_LEGACY_KEY"
      if link_.info.role == 1:
        host_.set-legacy-encryption-key link_ legacy_
        legacy_ = null
    else:
      key_ = candidate.key
      legacy_ = null
      if link_.info.role == 1:
        host_.set-encryption-key link_ key_
        key_ = null

  matches host/Central link/Link -> bool: return host == host_ and link == link_
  paired -> bool: return ready_ and not closed_ and link_.connected
  encrypted -> bool: return paired and link_.encrypted
  authenticated -> bool: return encrypted and authenticated_

  /**
  Establishes encryption once, or joins the attempt a Security Request started.

  On a central link the attempt starts here, or earlier when the peer's
    Security Request arrived (see $receive); either way this waits for its
    result within $timeout. On a peripheral link it waits for the controller's
    encryption result. Failure or cancellation aborts this link.
  */
  run --timeout/Duration=(Duration --s=30) -> none:
    if joined_ or closed_: throw "BLE_BOND_RESUME_INVALID_STATE"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    joined_ = true
    succeeded := false
    try:
      // On a peripheral link the attempt runs inline; cancellation during
      // it must reach the cleanup below as well.
      start_ timeout
      with-timeout timeout: result_.get
      succeeded = true
    finally:
      // A caller that stops waiting ends this security lifetime and its link.
      if not succeeded: close

  start_ timeout/Duration -> none:
    if used_: return
    used_ = true
    if link_.info.role == 0:
      // Encrypt on a background task so a Security Request can start the
      // attempt from the ATT receive task, which must not wait.
      worker_ = task --background --name="BLE bond resume"::
        attempt_ timeout
    else:
      attempt_ timeout

  attempt_ timeout/Duration -> none:
    // The outcome reaches run through the latch; the background worker must
    // not propagate it as an unhandled task exception, and a canceled worker
    // simply records that it stopped.
    error := catch:
      with-timeout timeout:
        if link_.info.role == 0:
          if legacy_:
            host_.encrypt-legacy link_ legacy_ --timeout=timeout
          else:
            host_.encrypt link_ key_ --timeout=timeout
        else:
          change := link_.wait-encryption-change
          if change.status != 0: throw (encryption.Error change.status)
          if not change.enabled: throw "HCI_ENCRYPTION_NOT_ENABLED"
        if closed_: throw "BLE_BOND_RESUME_CLOSED"
        link_.require-encryption
        ready_ = true
    critical-do --no-respect-deadline:
      key_ = null
      legacy_ = null
      worker_ = null
      if error:
        if not result_.has-value: result_.set error --exception
        close
      else if not result_.has-value:
        result_.set true

  /**
  Answers a peer's Security Request with the stored bond.

  On a central link the stored key is compared with the requested properties:
    a key that meets them is used for the encryption setup this owner performs
    (a request arriving after the setup started is ignored, since the
    encryption under way already answers it); a request for MITM protection
    that an unauthenticated key cannot meet is answered with Pairing Not
    Supported, because this owner never pairs. Replacement of a bond requires
    an explicit provider decision. Other SMP traffic is rejected.
  */
  receive bytes/ByteArray -> none:
    // The central's handling follows Core 6.3 Vol 3 Part H 2.4.6, Figure 2.7.
    if closed_: throw "BLE_BOND_RESUME_CLOSED"
    if bytes.size == 2 and bytes[0] == 0x0b and link_.info.role == 0:
      if used_: return
      if (bytes[1] & 4) != 0 and not authenticated_:
        host_.send link_ 6 #[5, 5]
        return
      // The stored key satisfies the request: encrypt now. Peers such as
      // BlueZ hold ATT traffic of a bonded central until the link is
      // encrypted, so waiting for the provider's own trigger would deadlock.
      start_ (Duration --s=30)
      return
    response := signaling.security-response bytes
    if response: host_.send link_ 6 response

  request-security -> none:
    if closed_: throw "BLE_BOND_RESUME_CLOSED"
    if link_.info.role != 1 or encrypted: return
    // Bonding, MITM as the bond has it, Secure Connections unless legacy.
    with-timeout timeouts.SEND:
      host_.send link_ 6 #[0x0b, 1 | (authenticated_ ? 4 : 0) | (legacy_ ? 0 : 8)]

  /** Ends this security lifetime and releases installed keys through link abort. */
  close -> none:
    // Runs from finally blocks of canceled tasks too; the latch and abort
    // must complete regardless.
    critical-do --no-respect-deadline:
      if closed_: return
      closed_ = true
      ready_ = false
      key_ = null
      legacy_ = null
      if not result_.has-value: result_.set "BLE_BOND_RESUME_CLOSED" --exception
      worker := worker_
      if worker and worker != Task.current: worker.cancel
      if link_.connected: host_.abort link_ --error="BLE_BOND_RESUME_CLOSED"
