// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto
import crypto.ec as ec
import .sc-crypto as sc
import .sc-ecdh as ecdh
import .smp-features as features
import .smp-legacy as legacy-pairing

/**
One pairing key exchange, without transport or persistence.

Secure Connections with Just Works, Numeric Comparison or Passkey Entry, and
  legacy pairing with Just Works or Passkey Entry. Methods return ordered SMP
  PDUs for the owner to enqueue. The owner must enforce $deadline and call
  $check-timeout even when no packet arrives. No task or callback is
  retained. Numeric Comparison requires an explicit $approve call; Passkey
  Entry shows $passkey-display on the displaying side and needs
  $enter-passkey on the inputting side (both input when both only have
  keyboards). A completed
  exchange exposes candidate key material, not an encrypted link. This engine is
  used by the pairing owner for key generation. Optional bonding features only
  negotiate a plan; the caller must perform encrypted distribution and persistence.
*/
class Session:
  initiator_/bool
  authentication_/bool
  local-address_/ByteArray
  peer-address_/ByteArray
  local_/features.Features := ?
  peer_/features.Features? := null
  state_/string := "idle"
  deadline_/int? := null
  failure_/int? := null
  method_/string? := null
  pair_/ec.EcKeyPair? := null
  public_/ByteArray? := null
  peer-public_/ByteArray? := null
  nonce_/ByteArray? := null
  peer-nonce_/ByteArray? := null
  confirm_/ByteArray? := null
  dhkey_/ByteArray? := null
  keys_/sc.Keys? := null
  own-check_/ByteArray? := null
  peer-check_/ByteArray? := null
  queued-check_/ByteArray? := null
  number_/int? := null
  ltk_/ByteArray? := null
  // Legacy pairing: the randoms and confirms in wire order.
  legacy-random_/ByteArray? := null
  legacy-peer-random_/ByteArray? := null
  legacy-peer-confirm_/ByteArray? := null
  // Passkey Entry: the passkey once known, whether this side types it, and
  // the round (SC uses one bit of it per round, 20 rounds).
  passkey_/int? := null
  passkey-inputs_/bool := false
  passkey-round_/int := 0

  /**
  Prepares one exchange.

  $io-capability is the SMP value: 0 display only, 1 display yes/no, 2
    keyboard only, 3 no input no output, 4 keyboard display. Without
    $secure-connections the local features only offer legacy pairing.
  */
  constructor --initiator/bool --io-capability/int --require-authentication/bool
      --local-address/ByteArray --peer-address/ByteArray
      --bond/bool=false --distribute-identity/bool=false --request-identity/bool=false
      --secure-connections/bool=true:
    if not 0 <= io-capability <= 4 or
        (require-authentication and io-capability == 3) or
        local-address.size != 7 or peer-address.size != 7 or
        local-address[0] > 1 or peer-address[0] > 1:
      throw "INVALID_ARGUMENT"
    if not bond and (distribute-identity or request-identity): throw "INVALID_ARGUMENT"
    initiator_ = initiator
    authentication_ = require-authentication
    local-address_ = local-address.copy
    peer-address_ = peer-address.copy
    // EncKey is asked for as well: SC ignores it, and a legacy peer that
    // bonds needs it to distribute its long term key.
    local_ = features.Features #[initiator ? 1 : 2, io-capability, 0,
                                (require-authentication ? 4 : 0) | (secure-connections ? 8 : 0) | (bond ? 1 : 0), 16,
                                ((initiator ? distribute-identity : request-identity) ? 2 : 0) | (bond ? 1 : 0),
                                ((initiator ? request-identity : distribute-identity) ? 2 : 0) | (bond ? 1 : 0)]
        --response=(not initiator)

  state -> string: return state_
  deadline -> int?: return deadline_
  failure -> int?: return failure_
  comparison-number -> int?: return state_ == "approval" ? number_ : null
  verified -> bool: return state_ == "complete"
  /** Tests the verified candidate key's association strength, not link encryption. */
  authenticated -> bool:
    return verified and (method_ == "numeric-comparison" or method_ == "passkey-entry" or method_ == "legacy-passkey-entry")
  /**
  Whether this exchange used legacy pairing: the key is a short term key for
    this connection only, and a bond needs the encrypted key distribution.
  */
  legacy -> bool: return method_ == "legacy-just-works" or method_ == "legacy-passkey-entry"

  passkey-method_ -> bool: return method_ == "passkey-entry" or method_ == "legacy-passkey-entry"

  /**
  The six-digit passkey this side displays for the other side to type, or
    null when this side does not display one (or the exchange ended).
  */
  passkey-display -> int?:
    if not passkey-method_ or passkey-inputs_ or state_ == "failed" or state_ == "complete": return null
    return passkey_

  /** Whether this side waits for its user to type the passkey the other side shows. */
  passkey-requested -> bool:
    return passkey-method_ and passkey-inputs_ and passkey_ == null and state_ != "failed" and state_ != "complete"

  /**
  Supplies the passkey typed by the user (0 to 999999) and returns the PDUs
    that can be sent now.
  */
  enter-passkey passkey/int --now/int=Time.monotonic-us -> List:
    check-timeout --now=now
    if not passkey-requested: throw "SMP_INVALID_STATE"
    if not 0 <= passkey <= 999_999: throw "INVALID_ARGUMENT"
    passkey_ = passkey
    if state_ == "legacy-await-passkey":
      if initiator_:
        state_ = "legacy-confirm"
        return output_ [#[3] + (legacy-confirm_ legacy-random_)] now
      state_ = "legacy-random"
      return output_ [#[3] + (legacy-confirm_ legacy-random_)] now
    if state_ == "pk-await-passkey":
      if initiator_:
        state_ = "pk-confirm"
        return output_ [passkey-confirm_] now
      state_ = "pk-random"
      return output_ [passkey-confirm_] now
    // Typed before the protocol needs it; the state machine uses it later.
    return []

  /** Ends the exchange because the user did not type a passkey (Passkey Entry Failed). */
  reject-passkey --now/int=Time.monotonic-us -> List:
    check-timeout --now=now
    if not passkey-requested: throw "SMP_INVALID_STATE"
    close
    failure_ = 1
    return [#[5, 1]]
  /** The negotiated legacy EncKey distribution directions: [initiator sends, responder sends]. */
  legacy-key-distribution -> List:
    if not verified or not legacy: throw "SMP_KEY_NOT_READY"
    response := initiator_ ? peer_ : local_
    if not local_.bonding or not peer_.bonding: return [false, false]
    return [response.initiator-encryption-key, response.responder-encryption-key]

  /** Reports mutual bonding intent only after the candidate key is verified. */
  bonding -> bool: return verified and local_.bonding and peer_.bonding

  /** Returns the negotiated local identity-distribution direction, not its completion. */
  distribute-identity -> bool:
    if not verified: throw "SMP_KEY_NOT_READY"
    response := initiator_ ? peer_ : local_
    return ((initiator_ ? response.initiator-keys : response.responder-keys) & 2) != 0

  /** Returns the negotiated peer identity-distribution direction. */
  receive-identity -> bool:
    if not verified: throw "SMP_KEY_NOT_READY"
    response := initiator_ ? peer_ : local_
    return ((initiator_ ? response.responder-keys : response.initiator-keys) & 2) != 0

  /** Returns a copy of the candidate LTK only after peer-check verification. */
  key -> ByteArray:
    if not verified: throw "SMP_KEY_NOT_READY"
    return ltk_.copy

  /**
  Returns a Security Request (Core 6.3 Vol 3 Part H 3.6.7) with this
    responder's AuthReq, asking the central to pair (or to encrypt with an
    existing bond). Only before pairing started.
  */
  security-request -> ByteArray:
    if initiator_ or state_ != "idle": throw "SMP_INVALID_STATE"
    return #[0x0b, local_.packet[3]]

  start --now/int=Time.monotonic-us -> List:
    if not initiator_ or state_ != "idle": throw "SMP_INVALID_STATE"
    state_ = "features"
    return output_ [local_.packet] now

  receive bytes/ByteArray --now/int=Time.monotonic-us -> List:
    check-timeout --now=now
    if state_ == "failed" or state_ == "complete": throw "SMP_INVALID_STATE"
    result/List? := null
    error := catch: result = receive_ bytes
    if error:
      clear_
      state_ = "failed"
      deadline_ = null
      if error is features.PairingError:
        failure_ = error.reason
        return [#[5, error.reason]]
      throw error
    return output_ result now

  approve accepted/bool --now/int=Time.monotonic-us -> List:
    check-timeout --now=now
    if state_ != "approval": throw "SMP_INVALID_STATE"
    if not accepted:
      close
      failure_ = 0x0c
      return [#[5, 0x0c]]
    if initiator_:
      state_ = "check"
      return output_ [(packet_ 0x0d own-check_)] now
    state_ = "check"
    if not queued-check_: return []
    check := queued-check_
    queued-check_ = null
    return receive (packet_ 0x0d check) --now=now

  check-timeout --now/int=Time.monotonic-us -> none:
    if deadline_ != null and now >= deadline_:
      close
      throw "SMP_TIMEOUT"

  close -> none:
    clear_
    ltk_ = null
    deadline_ = null
    state_ = "failed"

  receive_ bytes/ByteArray -> List:
    if bytes.is-empty: throw (features.PairingError 0x0a)
    code := bytes[0]
    // Core 6.3, Vol 3, Part H, 2.4.6: after sending Pairing Request, ignore
    // Security Requests until Pairing Response. This must not refresh the timer.
    if initiator_ and state_ == "features" and code == 0x0b and bytes.size == 2:
      return []
    if code == 0 or code == 0x0a or code > 0x0e: return []
    if code == 5:
      if bytes.size != 2 or bytes[1] == 0 or bytes[1] > 0x0f:
        throw (features.PairingError 0x0a)
      close
      failure_ = bytes[1]
      return []
    if (not initiator_ and state_ == "idle") or state_ == "features":
      peer_ = features.Features bytes --response=initiator_
      if not initiator_:
        response-bytes := local_.packet
        if not peer_.bonding:
          response-bytes[3] &= ~1
          response-bytes[5] = response-bytes[6] = 0
        else:
          // Keep what the peer offered, EncKey included (see the constructor).
          response-bytes[5] &= peer_.packet[5]
          response-bytes[6] &= peer_.packet[6]
        local_ = features.Features response-bytes --response
      request := initiator_ ? local_ : peer_
      response := initiator_ ? peer_ : local_
      method_ = features.select-association request response --require-authentication=authentication_
      if (not request.bonding or not response.bonding) and
          (response.initiator-keys != 0 or response.responder-keys != 0):
        throw (features.PairingError 3)
      if passkey-method_:
        roles := features.passkey-roles request.io-capability response.io-capability
        passkey-inputs_ = initiator_ ? roles[0] : roles[1]
        if not passkey-inputs_: passkey_ = random-passkey_
      if legacy:
        legacy-random_ = crypto.random --size=16
        if not initiator_:
          state_ = "legacy-confirm"
          return [local_.packet]
        if not legacy-tk-known_:
          state_ = "legacy-await-passkey"
          return []
        state_ = "legacy-confirm"
        return [#[3] + (legacy-confirm_ legacy-random_)]
      pair_ = ecdh.generate
      public_ = ecdh.public-key pair_.public-key
      nonce_ = crypto.random --size=16
      state_ = "public"
      return initiator_ ? [#[0x0c] + public_] : [local_.packet]
    if state_ == "legacy-confirm":
      if code != 3 or bytes.size != 17: throw (features.PairingError 0x0a)
      legacy-peer-confirm_ = bytes[1..].copy
      // The initiator reveals its random once it holds the responder's
      // confirm; the responder answers a confirm with its own confirm,
      // which needs the passkey.
      if initiator_:
        state_ = "legacy-random"
        return [#[4] + legacy-random_]
      if not legacy-tk-known_:
        state_ = "legacy-await-passkey"
        return []
      state_ = "legacy-random"
      return [#[3] + (legacy-confirm_ legacy-random_)]
    if state_ == "legacy-random":
      if code != 4 or bytes.size != 17: throw (features.PairingError 0x0a)
      legacy-peer-random_ = bytes[1..].copy
      if not (sc.verify-check (legacy-confirm_ legacy-peer-random_) legacy-peer-confirm_):
        throw (features.PairingError 4)
      mrand := initiator_ ? legacy-random_ : legacy-peer-random_
      srand := initiator_ ? legacy-peer-random_ : legacy-random_
      // The STK is a big-endian key like the SC LTK for the encryption commands.
      ltk_ = reverse_ (legacy-pairing.s1 legacy-tk_ srand mrand)
      result := initiator_ ? [] : [#[4] + legacy-random_]
      clear_
      state_ = "complete"
      deadline_ = null
      return result
    if state_ == "public":
      if code != 0x0c or bytes.size != 65: throw (features.PairingError 0x0a)
      peer-public_ = bytes[1..].copy
      error := catch: dhkey_ = ecdh.dhkey pair_.private-key peer-public_
      // Core 6.3, Vol 3, Part H, 2.3.5.6.1 requires Pairing Failed with
      // DHKey Check Failed for invalid peer points, without using an LTK.
      if error == "SMP_INVALID_PUBLIC_KEY": throw (features.PairingError 0x0b)
      // The same section permits Invalid Parameters when debug keys are not
      // accepted. Our host never enables Secure Connections debug mode.
      if error == "SMP_DEBUG_KEY_REJECTED": throw (features.PairingError 0x0a)
      if error: throw error
      if peer-public_[..32] == public_[..32]: throw (features.PairingError 0x0b)
      pair_ = null
      if method_ == "passkey-entry":
        // Passkey rounds: the initiator starts each one with its confirm.
        if not initiator_:
          state_ = "pk-confirm"
          return [#[0x0c] + public_]
        if passkey_ == null:
          state_ = "pk-await-passkey"
          return []
        state_ = "pk-confirm"
        return [passkey-confirm_]
      if initiator_:
        state_ = "confirm"
        return []
      state_ = "random"
      confirm := sc.f4 (reverse_ public_[..32]) (reverse_ peer-public_[..32]) nonce_ 0
      return [#[0x0c] + public_, (packet_ 3 confirm)]
    if state_ == "pk-confirm":
      if code != 3 or bytes.size != 17: throw (features.PairingError 0x0a)
      confirm_ = reverse_ bytes[1..]
      if initiator_:
        state_ = "pk-random"
        return [packet_ 4 nonce_]
      if passkey_ == null:
        state_ = "pk-await-passkey"
        return []
      state_ = "pk-random"
      return [passkey-confirm_]
    if state_ == "pk-random":
      if code != 4 or bytes.size != 17: throw (features.PairingError 0x0a)
      peer-nonce_ = reverse_ bytes[1..]
      z := 0x80 | ((passkey_ >> passkey-round_) & 1)
      expected := sc.f4 (reverse_ peer-public_[..32]) (reverse_ public_[..32]) peer-nonce_ z
      if not (sc.verify-check expected confirm_): throw (features.PairingError 4)
      passkey-round_++
      result := initiator_ ? [] : [packet_ 4 nonce_]
      if passkey-round_ < 20:
        state_ = "pk-confirm"
        if initiator_: result.add passkey-confirm_
        return result
      derive_
      state_ = "check"
      if initiator_: result.add (packet_ 0x0d own-check_)
      return result
    if state_ == "confirm":
      if code != 3 or bytes.size != 17: throw (features.PairingError 0x0a)
      confirm_ = reverse_ bytes[1..]
      state_ = "random"
      return [packet_ 4 nonce_]
    if state_ == "random":
      if code != 4 or bytes.size != 17: throw (features.PairingError 0x0a)
      peer-nonce_ = reverse_ bytes[1..]
      if initiator_:
        expected := sc.f4 (reverse_ peer-public_[..32]) (reverse_ public_[..32]) peer-nonce_ 0
        if not (sc.verify-check expected confirm_): throw (features.PairingError 4)
      derive_
      if method_ == "numeric-comparison":
        state_ = "approval"
        return initiator_ ? [] : [packet_ 4 nonce_]
      state_ = "check"
      return initiator_ ? [packet_ 0x0d own-check_] : [packet_ 4 nonce_]
    if state_ == "approval" and not initiator_ and code == 0x0d:
      if bytes.size != 17 or queued-check_: throw (features.PairingError 0x0a)
      queued-check_ = reverse_ bytes[1..]
      return []
    if state_ == "check":
      if code != 0x0d or bytes.size != 17: throw (features.PairingError 0x0a)
      if not (sc.verify-check peer-check_ (reverse_ bytes[1..])):
        throw (features.PairingError 0x0b)
      result := initiator_ ? [] : [packet_ 0x0d own-check_]
      ltk_ = keys_.ltk.copy
      clear_
      state_ = "complete"
      deadline_ = null
      return result
    throw (features.PairingError 0x0a)

  /**
  Returns the SC Passkey Entry confirm for the current round, starting it
    with a fresh nonce.
  */
  passkey-confirm_ -> ByteArray:
    nonce_ = crypto.random --size=16
    z := 0x80 | ((passkey_ >> passkey-round_) & 1)
    return packet_ 3 (sc.f4 (reverse_ public_[..32]) (reverse_ peer-public_[..32]) nonce_ z)

  /** Whether the legacy TK is known: always for Just Works, once typed or generated for Passkey Entry. */
  legacy-tk-known_ -> bool: return method_ == "legacy-just-works" or passkey_ != null

  /** The legacy TK in wire order: zero for Just Works, the passkey for Passkey Entry. */
  legacy-tk_ -> ByteArray:
    tk := ByteArray 16
    if method_ == "legacy-passkey-entry":
      tk[0] = passkey_ & 0xff
      tk[1] = (passkey_ >> 8) & 0xff
      tk[2] = passkey_ >> 16
    return tk

  /** c1 over the exchange with the legacy TK for one of the two randoms. */
  legacy-confirm_ random/ByteArray -> ByteArray:
    request := initiator_ ? local_ : peer_
    response := initiator_ ? peer_ : local_
    initiating := initiator_ ? local-address_ : peer-address_
    responding := initiator_ ? peer-address_ : local-address_
    iat := initiating[0]
    ia := reverse_ initiating[1..]
    rat := responding[0]
    ra := reverse_ responding[1..]
    return legacy-pairing.c1 legacy-tk_ random request.packet response.packet iat ia rat ra

  derive_ -> none:
    na := initiator_ ? nonce_ : peer-nonce_
    nb := initiator_ ? peer-nonce_ : nonce_
    a := initiator_ ? local-address_ : peer-address_
    b := initiator_ ? peer-address_ : local-address_
    request := initiator_ ? local_ : peer_
    response := initiator_ ? peer_ : local_
    keys_ = sc.f5 dhkey_ na nb a b
    // Passkey Entry checks with the passkey as r (a 128-bit big-endian value).
    r := ByteArray 16
    if method_ == "passkey-entry":
      r[13] = passkey_ >> 16
      r[14] = (passkey_ >> 8) & 0xff
      r[15] = passkey_ & 0xff
    ea := sc.f6 keys_.mac-key na nb r request.check-iocap a b
    eb := sc.f6 keys_.mac-key nb na r response.check-iocap b a
    own-check_ = initiator_ ? ea : eb
    peer-check_ = initiator_ ? eb : ea
    if method_ == "numeric-comparison":
      ax := reverse_ (initiator_ ? public_[..32] : peer-public_[..32])
      bx := reverse_ (initiator_ ? peer-public_[..32] : public_[..32])
      number_ = (sc.g2 ax bx na nb) % 1_000_000
    dhkey_ = null

  output_ packets/List now/int -> List:
    if not packets.is-empty and state_ != "failed" and state_ != "complete":
      deadline_ = now + 30_000_000
    return packets

  clear_ -> none:
    pair_ = null
    public_ = null
    peer-public_ = null
    nonce_ = null
    peer-nonce_ = null
    confirm_ = null
    dhkey_ = null
    keys_ = null
    own-check_ = null
    peer-check_ = null
    queued-check_ = null
    number_ = null
    legacy-random_ = null
    legacy-peer-random_ = null
    legacy-peer-confirm_ = null
    passkey_ = null

/** A uniformly distributed six-digit passkey. */
random-passkey_ -> int:
  while true:
    bytes := crypto.random --size=3
    value := (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16)) & 0xfffff
    if value < 1_000_000: return value

reverse_ bytes/ByteArray -> ByteArray:
  return ByteArray bytes.size: bytes[bytes.size - 1 - it]

packet_ opcode/int big/ByteArray -> ByteArray:
  return #[opcode] + (reverse_ big)
