// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .smp-identity show Identity
import .smp-legacy show LegacyKey

/**
Owned candidate material for a 128-bit LE Secure Connections bond.

Contains secrets. Encoding is a record format, not encryption or protected
  storage. Trusted storage code must supply confidentiality, integrity and
  atomic replacement. This object makes no claim about peer delivery, durable
  commit, or the security of a current connection. It does not implement
  SecurityState. Addresses are stable public/static identities, never RPAs.
*/
class Candidate:
  key_/ByteArray
  local/Identity
  peer/Identity
  authenticated/bool
  /**
  Legacy pairing keys, null for a Secure Connections bond.

  $peer-legacy is what the peer distributed: a central resumes by starting
    encryption with its EDIV and Rand. $local-legacy is what this side
    distributed: a peripheral answers the peer's LTK request with it. A side
    that did not distribute has null there.
  */
  peer-legacy/LegacyKey?
  local-legacy/LegacyKey?

  constructor key/ByteArray .local .peer --.authenticated --.peer-legacy=null --.local-legacy=null:
    if key.size != 16: throw "INVALID_ARGUMENT"
    key_ = key.copy

  /** Whether this bond came from legacy pairing and resumes through EDIV/Rand keys. */
  legacy -> bool: return peer-legacy != null or local-legacy != null

  /** Returns an owned LTK in big-endian cryptographic order. */
  key -> ByteArray: return key_.copy

  /**
  Encodes secret material for a trusted storage implementation.

  Version 1 has fixed length: marker/version, authenticated flag, LTK, local
    identity (type/address/IRK), then peer identity. A zero IRK denotes no
    address-resolution capability. It does not denote an absent identity.
  Version 2 (legacy bonds) appends a presence byte (bit 0 peer key, bit 1
    local key) and each present key as LTK (16), EDIV (2, little endian)
    and Rand (8).
  */
  encode -> ByteArray:
    local-bytes := #[local.address-type] + local.address + local.irk
    peer-bytes := #[peer.address-type] + peer.address + peer.irk
    if not legacy:
      return #[0x54, 0x42, 1, authenticated ? 1 : 0] + key_ + local-bytes + peer-bytes
    presence := (peer-legacy ? 1 : 0) | (local-legacy ? 2 : 0)
    result := #[0x54, 0x42, 2, authenticated ? 1 : 0] + key_ + local-bytes + peer-bytes + #[presence]
    if peer-legacy: result += encode-legacy_ peer-legacy
    if local-legacy: result += encode-legacy_ local-legacy
    return result

  static encode-legacy_ key/LegacyKey -> ByteArray:
    return key.ltk + #[key.ediv & 0xff, key.ediv >> 8] + key.rand

  static decode-legacy_ bytes/ByteArray -> LegacyKey:
    return LegacyKey bytes[0..16].copy (bytes[16] | (bytes[17] << 8)) bytes[18..26].copy

  /** Decodes a record whose authenticity the caller has already established. */
  static decode bytes/ByteArray -> Candidate:
    if bytes.size < 66 or bytes[0] != 0x54 or bytes[1] != 0x42 or bytes[3] > 1:
      throw "BLE_INVALID_BOND_RECORD"
    version := bytes[2]
    if version != 1 and version != 2: throw "BLE_INVALID_BOND_RECORD"
    if version == 1 and bytes.size != 66: throw "BLE_INVALID_BOND_RECORD"
    peer-legacy/LegacyKey? := null
    local-legacy/LegacyKey? := null
    if version == 2:
      if bytes.size < 67: throw "BLE_INVALID_BOND_RECORD"
      presence := bytes[66]
      count := (presence & 1) + ((presence >> 1) & 1)
      if presence > 3 or count == 0 or bytes.size != 67 + 26 * count: throw "BLE_INVALID_BOND_RECORD"
      offset := 67
      if presence & 1 != 0:
        peer-legacy = decode-legacy_ bytes[offset..]
        offset += 26
      if presence & 2 != 0: local-legacy = decode-legacy_ bytes[offset..]
    local/Identity? := null
    peer/Identity? := null
    error := catch:
      local = Identity bytes[27..43] bytes[21..27] bytes[20]
      peer = Identity bytes[50..66] bytes[44..50] bytes[43]
    if error == "INVALID_ARGUMENT": throw "BLE_INVALID_BOND_RECORD"
    if error: throw error
    return Candidate bytes[4..20] local peer
        --authenticated=(bytes[3] == 1)
        --peer-legacy=peer-legacy
        --local-legacy=local-legacy
