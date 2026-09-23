// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/** Pairing feature parsing and association selection; no pairing is enabled here. */

/** An SMP failure reason suitable for a later Pairing Failed response. */
class PairingError:
  reason/int

  constructor .reason:

  stringify -> string: return "SMP_PAIRING_FAILED reason=$reason"

/** An owned, validated Pairing Request or Response (Core 6.3 Part H, 3.5.1–2). */
class Features:
  bytes_/ByteArray

  constructor bytes/ByteArray --response/bool=false:
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

Requires both SC bits and key sizes of 16. Numeric Comparison and Passkey Entry
  are selected by Core 6.3 Vol 3 Part H Table 2.8 when either MITM flag is set.
  Just Works cannot satisfy an explicit local authentication requirement. A local requirement
  also cannot retroactively change already exchanged flags. OOB is not supported.
  The returned method is a plan, never evidence that authentication succeeded.
  The pairing session executes Just Works and Numeric Comparison separately.
  Passkey Entry execution is unsupported by the host.
*/
select-association request/Features response/Features --require-authentication/bool -> string:
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
  if a == 3 or b == 3 or (a < 2 and b < 2):
    if require-authentication: throw (PairingError 3)
    return "just-works"
  return "passkey-entry"

/**
Selects the legacy (non Secure Connections) association when either side
  lacks SC: Just Works with a full 128-bit key only, unauthenticated.

Legacy Passkey Entry and OOB are not executed by the host; a peer that asks
  for MITM protection with capable IO is refused (reason 3), as is a local
  authentication requirement, since legacy Just Works cannot satisfy it.
*/
select-legacy-association request/Features response/Features --require-authentication/bool -> string:
  if request.key-size != 16 or response.key-size != 16: throw (PairingError 6)
  if request.oob or response.oob: throw (PairingError 2)
  if require-authentication: throw (PairingError 3)
  if response.initiator-keys & ~request.initiator-keys != 0 or
      response.responder-keys & ~request.responder-keys != 0:
    throw (PairingError 0x0a)
  if request.mitm or response.mitm:
    a := request.io-capability
    b := response.io-capability
    // Table 2.8 for legacy: no IO on either side, or both display only, is Just Works.
    if a == 3 or b == 3 or (a < 2 and b < 2): return "legacy-just-works"
    throw (PairingError 3)
  return "legacy-just-works"
