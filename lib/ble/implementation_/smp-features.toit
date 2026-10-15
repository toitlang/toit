// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The pairing feature exchange: what each side offers and what follows from it.

$Features parses and validates a Pairing Request or Response PDU.
  $select-association decides from the two of them which pairing method
  runs (Just Works, Numeric Comparison or Passkey Entry, Secure Connections
  or legacy through $select-legacy-association), and $passkey-roles says
  which side types the passkey. $PairingError carries the reason of a
  failed pairing. The pairing engine (`smp-pairing`) uses these; no pairing
  is performed here.
*/

/** An SMP failure reason suitable for a later Pairing Failed response. */
class PairingError:
  reason/int

  constructor .reason:

  stringify -> string: return "SMP_PAIRING_FAILED reason=$reason"

/** An owned, validated Pairing Request or Response PDU. */
class Features:
  bytes_/ByteArray

  constructor bytes/ByteArray --response/bool=false:
    // The layout is that of Core 6.3 Vol 3 Part H 3.5.1 and 3.5.2.
    if bytes.size != 7 or bytes[0] != (response ? 2 : 1) or
        bytes[1] > 4 or bytes[2] > 1 or (bytes[3] & 3) > 1 or
        not 7 <= bytes[4] <= 16:
      throw (PairingError 0x0a)
    bytes_ = bytes.copy

  response -> bool: return bytes_[0] == 2
  io-capability -> int: return bytes_[1]
  oob -> bool: return bytes_[2] == 1
  mitm -> bool: return bytes_[3] & 4 != 0
  secure-connections -> bool: return bytes_[3] & 8 != 0
  bonding -> bool: return bytes_[3] & 3 == 1
  key-size -> int: return bytes_[4]

  /** Returns the known SC distribution bits; EncKey and obsolete/RFU bits are ignored. */
  initiator-keys -> int: return bytes_[5] & 0x0a
  responder-keys -> int: return bytes_[6] & 0x0a
  /** Returns the legacy EncKey distribution bits, which SC ignores. */
  initiator-encryption-key -> bool: return bytes_[5] & 1 != 0
  responder-encryption-key -> bool: return bytes_[6] & 1 != 0

  /** Returns f6's AuthReq/OOB/IOcap order, preserving the exchanged AuthReq byte. */
  check-iocap -> ByteArray: return #[bytes_[3], bytes_[2], bytes_[1]]

  /** Returns a fresh copy of the exchanged PDU. */
  packet -> ByteArray: return bytes_.copy

/**
Selects an SC association with full 128-bit keys and explicit authentication policy.

Requires both SC bits and key sizes of 16. When either side asks for MITM
  protection, the two IO capabilities decide between Numeric Comparison and
  Passkey Entry (see $passkey-roles), falling back to Just Works when neither
  is possible. Just Works cannot satisfy an explicit local authentication
  requirement. A local requirement also cannot retroactively change already
  exchanged flags. OOB is not supported.
  The returned method is a plan, never evidence that authentication succeeded.
  The pairing session executes it.
*/
select-association request/Features response/Features --require-authentication/bool -> string:
  // The method selection is Core 6.3 Vol 3 Part H Table 2.8.
  if request.response or not response.response: throw (PairingError 0x0a)
  if not request.secure-connections or not response.secure-connections:
    return select-legacy-association request response --require-authentication=require-authentication
  if request.key-size != 16 or response.key-size != 16: throw (PairingError 6)
  if response.initiator-keys & ~request.initiator-keys != 0 or
      response.responder-keys & ~request.responder-keys != 0:
    throw (PairingError 0x0a)
  if request.oob or response.oob: throw (PairingError 2)
  mitm := request.mitm or response.mitm
  if not mitm:
    if require-authentication: throw (PairingError 3)
    return "just-works"
  a := request.io-capability
  b := response.io-capability
  if (a == 1 or a == 4) and (b == 1 or b == 4): return "numeric-comparison"
  // NoInputNoOutput, or two display-only-capable devices, cannot authenticate.
  if (passkey-roles a b) == null:
    if require-authentication: throw (PairingError 3)
    return "just-works"
  return "passkey-entry"

/**
Selects the legacy (non Secure Connections) association when either side
  lacks SC: Just Works or Passkey Entry, with a full 128-bit key only.

OOB is not supported. A local authentication requirement is met only by
  Passkey Entry.
*/
select-legacy-association request/Features response/Features --require-authentication/bool -> string:
  if request.key-size != 16 or response.key-size != 16: throw (PairingError 6)
  if request.oob or response.oob: throw (PairingError 2)
  if response.initiator-keys & ~request.initiator-keys != 0 or
      response.responder-keys & ~request.responder-keys != 0:
    throw (PairingError 0x0a)
  if (request.mitm or response.mitm) and
      (passkey-roles request.io-capability response.io-capability) != null:
    return "legacy-passkey-entry"
  if require-authentication: throw (PairingError 3)
  return "legacy-just-works"

/**
Returns who enters the passkey for Passkey Entry between IO capabilities
  $initiator and $responder, as [initiator inputs, responder inputs], or
  null when the pair cannot use Passkey Entry. The side that does not input
  displays the passkey.

IO capabilities: 0 display only, 1 display yes/no, 2 keyboard only, 3 no
  input no output, 4 keyboard display. With Secure Connections, two
  display-yes/no-capable sides use Numeric Comparison instead.
*/
passkey-roles initiator/int responder/int -> List?:
  // The roles are those of Core 6.3 Vol 3 Part H Table 2.8.
  if initiator == 3 or responder == 3: return null
  if initiator == 2 and responder == 2: return [true, true]
  if initiator == 2: return [true, false]
  if responder == 2: return [false, true]
  if initiator < 2 and responder < 2: return null
  // One side has a keyboard and a display (4), the other a display: the
  // keyboard-display side inputs unless both have one, then the responder.
  if responder == 4: return [false, true]
  return [true, false]
