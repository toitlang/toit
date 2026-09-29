// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import .bond as bond
import .pairing-attempts as retry
import .security-owner show Owner
import .central as central
import .encryption as encryption
import .smp-identity as identity
import .smp-distribution as distribution
import .smp-legacy as legacy
import .smp-pairing as smp
import .smp-features show PairingError
import .signaling as signaling
import .timeouts as timeouts

monitor Progress_:
  version_/int := 0
  version -> int: return version_
  changed -> none: version_++
  wait version/int -> none: await: version_ != version

/**
An explicit pairing owner, unbonded by default, attached to one ATT client or GATT server.

Call $run while the ATT receiver is active. The confirmation block receives a
  six-digit Numeric Comparison value and must return a bool. It is never stored
  or called by the receive task. Just Works does not call it. The local address
  is the six HCI-order bytes actually used to create this connection, with its
  public/random type. An identity address must not replace an on-air private
  address in this cryptographic context. Pairing timeout and
  failure abort the link; only one attempt is allowed on this object.
  A shared --attempts policy additionally limits retries across objects. Its
  --attempt-identity defaults to the typed on-air peer address; trusted callers
  must supply a resolved stable identity for known private peers. Without a
  shared policy, the caller remains responsible for cross-connection delays.

Setting --bond, providing an identity, or requesting one opts into bonding
  intent. Identity options also request encrypted
  identity distribution. Run waits for negotiated peer identity and local packet
  submission, not peer delivery or durable bond storage. The received identity
  is candidate data only. Defaults preserve unbonded pairing.
*/
class Pairing implements Owner:
  host_/central.Central
  link_/central.Link
  engine_/smp.Session
  mutex_/monitor.Mutex ::= monitor.Mutex
  progress_/Progress_ ::= Progress_
  timer_/Task? := null
  timer-ended_/monitor.Latch ::= monitor.Latch
  active_/bool := false
  used_/bool := false
  ready_/bool := false
  complete_/bool := false
  encrypting_/bool := false
  authenticated_/bool := false
  local-address_/ByteArray
  local-address-type_/int
  identity_/identity.Identity? := ?
  distribution_/distribution.Exchange? := null
  distribution-deadline_/int? := null
  distribution-done_/bool := false
  peer-identity_/identity.Identity? := null
  local-legacy_/legacy.LegacyKey? := null
  peer-legacy_/legacy.LegacyKey? := null
  attempts_/retry.Attempts?
  attempt-identity_/ByteArray? := null
  error_ := null
  verified-failure-reason_/int? := null

  constructor .host_ .link_ --local-address/ByteArray --io-capability/int
      --require-authentication/bool --local-address-type/int=0
      --identity/identity.Identity?=null --request-identity/bool=false --bond/bool=false
      --attempts/retry.Attempts?=null --attempt-identity/ByteArray?=null:
    if not (host_.owns-link link_) or local-address.size != 6 or not 0 <= local-address-type <= 1:
      throw "INVALID_ARGUMENT"
    local-address_ = local-address.copy
    local-address-type_ = local-address-type
    identity_ = identity
    selected := link_.local-random-address
    if local-address-type != (selected ? 1 : 0) or (selected and local-address != selected):
      throw "SMP_WRONG_LOCAL_ADDRESS"
    attempts_ = attempts
    if attempts:
      selected-identity := attempt-identity or (#[link_.info.address-type] + link_.info.address)
      if selected-identity.size != 7 or not 0 <= selected-identity[0] <= 1: throw "INVALID_ARGUMENT"
      attempt-identity_ = selected-identity.copy
    else if attempt-identity:
      throw "INVALID_ARGUMENT"
    peer := link_.info.address
    local-context := #[local-address-type] + (ByteArray 6: local-address[5 - it])
    peer-context := #[link_.info.address-type] + (ByteArray 6: peer[5 - it])
    engine_ = smp.Session --initiator=(link_.info.role == 0)
        --io-capability=io-capability
        --require-authentication=require-authentication
        --local-address=local-context
        --peer-address=peer-context
        --bond=(bond or identity != null or request-identity)
        --distribute-identity=(identity != null)
        --request-identity=request-identity

  matches host/central.Central link/central.Link -> bool:
    return host == host_ and link == link_

  /** Reports a verified key belonging to this live connection. */
  paired -> bool: return ready_ and not error_ and link_.connected

  /** Tests whether this exchange finished and the controller still reports encryption. */
  encrypted -> bool: return complete_ and link_.encrypted
  /** Tests the completed association's strength while the link remains encrypted. */
  authenticated -> bool: return encrypted and authenticated_

  /**
  Returns the known SMP failure reason, independently of transport cleanup.

  Remains available after closure. A drain timeout can be thrown by run even
    when this reason is known; the reason does not prove peer receipt of a
    locally generated failure. Returns null when no SMP reason was established,
    including ordinary cancellation, timeout and retry-admission refusal.
  */
  failure-reason -> int?: return verified-failure-reason_ or engine_.failure

  /** Returns candidate distributed peer identity, not proof of a durable bond. */
  peer-identity -> identity.Identity?:
    if not distribution-done_ or not encrypted: throw "SMP_IDENTITY_NOT_READY"
    return peer-identity_

  /**
  Pairs, calling $confirm with the six-digit number for Numeric Comparison.

  For Passkey Entry, $display receives the six-digit passkey this side shows,
    once, and $input is called when the user must type the passkey the peer
    shows; it returns the passkey, or null when the user gives up (Passkey
    Entry Failed). Both run in the pairing task; $input may wait for the
    user within the SMP timeout.
  */
  run [confirm] --display/Lambda?=null --input/Lambda?=null -> none:
    run_ display input confirm: null

  /**
  Invokes a scoped storage block with candidate material before discarding the LTK.

  Requires mutual bonding intent and stable identities. The block may retain
    the owned candidate, but must not label it committed solely because it was
    called. Exceptions abort this connection. No candidate is produced after
    partial/failed distribution or without controller encryption. The block is
    called by the pairing task, never the receive task, and is not stored.
  */
  run [confirm] [--candidate] --display/Lambda?=null --input/Lambda?=null -> none:
    run_ display input confirm:
      if not engine_.bonding: throw "SMP_BOND_NOT_NEGOTIATED"
      if not encrypted: throw "SMP_IDENTITY_NOT_ENCRYPTED"
      local := identity_ or (stable-identity_ local-address_ local-address-type_)
      peer := peer-identity_ or (stable-identity_ link_.info.address link_.info.address-type)
      if engine_.legacy:
        // The STK only protects this connection; a legacy bond consists of
        // the distributed long term keys, and a bond without any is useless.
        if not local-legacy_ and not peer-legacy_: throw "SMP_BOND_KEYS_REQUIRED"
        candidate.call (bond.Candidate (ByteArray 16) local peer
            --authenticated=authenticated_
            --peer-legacy=peer-legacy_
            --local-legacy=local-legacy_)
      else:
        candidate.call (bond.Candidate engine_.key local peer --authenticated=authenticated_)
      if error_: throw error_
      if not encrypted: throw "SMP_IDENTITY_NOT_ENCRYPTED"

  run_ display/Lambda? input/Lambda? [confirm] [completed] -> none:
    if used_ or error_: throw "SMP_INVALID_STATE"
    if not attempts_:
      run-attempt_ display input confirm completed
      return
    error := catch:
      attempts_.with-attempt attempt-identity_: run-attempt_ display input confirm completed
    if error:
      fail_ error
      throw error

  run-attempt_ display/Lambda? input/Lambda? [confirm] [completed] -> none:
    if used_ or error_: throw "SMP_INVALID_STATE"
    used_ = true
    active_ = true
    succeeded := false
    try:
      timer_ = task --background --name="SMP deadline"::
        try:
          watch_
        finally:
          critical-do --no-respect-deadline: timer-ended_.set true
      if link_.info.role == 0:
        mutex_.do: send_ engine_.start
      displayed := false
      while not ready_:
        version := progress_.version
        if error_: throw error_
        passkey := engine_.passkey-display
        if passkey != null and not displayed:
          displayed = true
          if not display: throw "SMP_PASSKEY_DISPLAY_UNSUPPORTED"
          display.call passkey
        number := engine_.comparison-number
        if engine_.passkey-requested:
          typed/int? := null
          if input:
            remaining := engine_.deadline - Time.monotonic-us
            if remaining <= 0: throw "SMP_TIMEOUT"
            input-error := catch:
              typed = with-timeout (Duration --us=remaining): input.call
            if input-error:
              if input-error == DEADLINE-EXCEEDED-ERROR and Time.monotonic-us >= engine_.deadline:
                fail_ "SMP_TIMEOUT"
                throw "SMP_TIMEOUT"
              throw input-error
          mutex_.do:
            if error_: throw error_
            // A rejected entry fails the engine; send_ reports its reason.
            send_ (typed == null ? engine_.reject-passkey : (engine_.enter-passkey typed))
        else if number != null:
          deadline := engine_.deadline
          remaining := deadline - Time.monotonic-us
          if remaining <= 0: throw "SMP_TIMEOUT"
          accepted/bool := false
          confirmation-error := catch:
            accepted = with-timeout (Duration --us=remaining): confirm.call number
          if confirmation-error:
            if confirmation-error == DEADLINE-EXCEEDED-ERROR and Time.monotonic-us >= deadline:
              fail_ "SMP_TIMEOUT"
              throw "SMP_TIMEOUT"
            throw confirmation-error
          mutex_.do:
            if error_: throw error_
            send_ (engine_.approve accepted)
        else if not ready_:
          progress_.wait version
      if error_: throw error_
      authenticated_ = engine_.authenticated
      if link_.info.role == 0:
        encrypting_ = true
        try:
          host_.encrypt link_ engine_.key
        finally:
          encrypting_ = false
      else:
        with-timeout timeouts.SECURITY:
          change := link_.wait-encryption-change
          if error_: throw error_
          if change.status != 0: throw (encryption.Error change.status)
          if not change.enabled: throw "HCI_ENCRYPTION_NOT_ENABLED"
      mutex_.do: start-distribution_
      while distribution_ and not peer-distribution-complete_:
        version := progress_.version
        if error_: throw error_
        peer-identity_ = distribution_.peer-identity
        peer-legacy_ = distribution_.peer-legacy-key
        if not peer-distribution-complete_: progress_.wait version
      if error_: throw error_
      distribution-done_ = true
      completed.call
      succeeded = true
    finally:
      critical-do --no-respect-deadline:
        if not succeeded: fail_ (error_ or "SMP_PAIRING_ABORTED")
        active_ = false
        engine_.close
        if distribution_: distribution_.close
        distribution_ = null
        identity_ = null
        distribution-deadline_ = null
        progress_.changed
        if timer_: timer_.cancel
      if timer_:
        critical-do --no-respect-deadline:
          with-timeout timeouts.JOIN: timer-ended_.get

  /**
  Asks the central to start pairing with a Security Request, as the
    peripheral; $run, already waiting for it, then pairs as usual.

  Does nothing when pairing already started or finished: a central that is
    pairing or has paired needs no request.
  */
  request-security -> none:
    if link_.info.role != 1: throw "SMP_NOT_PERIPHERAL"
    mutex_.do:
      if error_: throw error_
      if engine_.state != "idle": return
      with-timeout timeouts.SEND: host_.send link_ 6 engine_.security-request

  /** Dispatches one SMP PDU from the owning ATT receive loop. */
  receive bytes/ByteArray -> none:
    if not active_:
      response := signaling.security-response bytes
      if response: host_.send link_ 6 response
      return
    error := catch:
      mutex_.do:
        if error_: throw error_
        // Core 6.3, Vol 3, Part H, 2.4.6 requires ignoring Security Requests
        // during central encryption setup, including after fresh pairing.
        if encrypting_ and bytes.size == 2 and bytes[0] == 0x0b: return
        if engine_.verified:
          if bytes.size > 0 and (bytes[0] == 0 or bytes[0] == 0x0a or bytes[0] > 0x0e): return
          // Core Vol 3 Part H 3.5.5: Pairing Failed also applies while waiting
          // for encryption; it is not identity distribution and does not
          // require bonding intent.
          if bytes.size > 0 and bytes[0] == 5:
            verified-failure-reason_ = bytes.size == 2 and 1 <= bytes[1] <= 0x0f
                ? bytes[1]
                : 0x0a
            if bytes.size != 2 or not 1 <= bytes[1] <= 0x0f:
              // Part H 2.3 requires an Invalid Parameters response. Bound its
              // submission and drain before the existing terminal cleanup.
              with-timeout timeouts.SEND: host_.send link_ 6 #[5, 0x0a]
              host_.drain link_
              throw (PairingError 0x0a)
            throw (PairingError bytes[1])
          if not engine_.bonding or not link_.encrypted: throw "SMP_IDENTITY_NOT_ENCRYPTED"
          start-distribution_
          send-distribution_ (distribution_.receive bytes)
          peer-identity_ = distribution_.peer-identity
          peer-legacy_ = distribution_.peer-legacy-key
          progress_.changed
        else:
          send_ (engine_.receive bytes)
    if error:
      fail_ error
      throw error

  /** Aborts pending pairing and releases its ephemeral references. */
  close -> none:
    fail_ "SMP_CLOSED"

  send_ packets/List -> none:
    if error_: throw error_
    // Install the responder's verified key before releasing its final DHKey
    // Check: the central may immediately request controller encryption.
    if engine_.verified and link_.info.role == 1:
      host_.set-encryption-key link_ engine_.key
    packets.do: | bytes/ByteArray |
      if error_: throw error_
      with-timeout timeouts.SEND: host_.send link_ 6 bytes
    if engine_.state == "failed":
      // Give a generated Pairing Failed response a bounded controller drain
      // before fail_ shuts down this link's transport. This is not a peer ack.
      if not packets.is-empty: host_.drain link_
      throw (PairingError (engine_.failure or 0x08))
    ready_ = engine_.verified
    progress_.changed

  start-distribution_ -> none:
    if distribution_: return
    link_.require-encryption
    authenticated_ = engine_.authenticated
    complete_ = true
    if not engine_.bonding: return
    receive-key := false
    if engine_.legacy:
      initiator := link_.info.role == 0
      directions := engine_.legacy-key-distribution
      if directions[initiator ? 0 : 1]: local-legacy_ = legacy.LegacyKey.random
      receive-key = directions[initiator ? 1 : 0]
    distribution_ = distribution.Exchange this --initiator=(link_.info.role == 0)
        --local=(engine_.distribute-identity ? identity_ : null)
        --receive-identity=engine_.receive-identity
        --local-key=local-legacy_
        --receive-key=receive-key
    distribution-deadline_ = Time.monotonic-us + 30_000_000
    send-distribution_ distribution_.start
    progress_.changed

  peer-distribution-complete_ -> bool:
    if engine_.receive-identity and not peer-identity_: return false
    if engine_.legacy and engine_.legacy-key-distribution[link_.info.role == 0 ? 1 : 0] and not peer-legacy_:
      return false
    return true

  send-distribution_ packets/List -> none:
    packets.do: | bytes/ByteArray |
      if error_: throw error_
      with-timeout timeouts.SEND: host_.send link_ 6 bytes
    // Submission is not peer delivery; this phase exposes candidate data only.
    if not packets.is-empty: distribution-deadline_ = Time.monotonic-us + timeouts.SECURITY.in-us

  watch_ -> none:
    while active_ and not error_:
      version := progress_.version
      deadline := distribution-deadline_ or engine_.deadline
      if deadline == null:
        progress_.wait version
        continue
      remaining := deadline - Time.monotonic-us
      if remaining <= 0:
        fail_ "SMP_TIMEOUT"
        return
      error := catch:
        with-timeout (Duration --us=remaining): progress_.wait version
      if error and error != DEADLINE-EXCEEDED-ERROR:
        fail_ error
        return

  fail_ error -> none:
    critical-do --no-respect-deadline:
      if error_: return
      error_ = error
      active_ = false
      complete_ = false
      engine_.close
      if distribution_: distribution_.close
      distribution_ = null
      identity_ = null
      peer-identity_ = null
      local-legacy_ = null
      peer-legacy_ = null
      distribution-done_ = false
      distribution-deadline_ = null
      progress_.changed
      if timer_ and timer_ != Task.current: timer_.cancel
      if link_.connected: host_.abort link_ --error=error

// Missing IdKey is permitted only when the on-air address is already stable.
// An all-zero IRK explicitly prevents treating that address as resolvable.
stable-identity_ address/ByteArray type/int -> identity.Identity:
  if type == 1 and address[5] & 0xc0 != 0xc0: throw "SMP_BOND_IDENTITY_REQUIRED"
  return identity.Identity (ByteArray 16) address type
