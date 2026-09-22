// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .smp-identity show Identity

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

  constructor key/ByteArray .local .peer --.authenticated:
    if key.size != 16: throw "INVALID_ARGUMENT"
    key_ = key.copy

  /** Returns an owned LTK in big-endian cryptographic order. */
  key -> ByteArray: return key_.copy

  /**
  Encodes secret material for a trusted storage implementation.

  Version 1 has fixed length: marker/version, authenticated flag, LTK, local
    identity (type/address/IRK), then peer identity. A zero IRK denotes no
    address-resolution capability. It does not denote an absent identity.
  */
  encode -> ByteArray:
    local-bytes := #[local.address-type] + local.address + local.irk
    peer-bytes := #[peer.address-type] + peer.address + peer.irk
    return #[0x54, 0x42, 1, authenticated ? 1 : 0] + key_ + local-bytes + peer-bytes

  /** Decodes a record whose authenticity the caller has already established. */
  static decode bytes/ByteArray -> Candidate:
    if bytes.size != 66 or bytes[0] != 0x54 or bytes[1] != 0x42 or bytes[2] != 1 or bytes[3] > 1:
      throw "BLE_INVALID_BOND_RECORD"
    local/Identity? := null
    peer/Identity? := null
    error := catch:
      local = Identity bytes[27..43] bytes[21..27] bytes[20]
      peer = Identity bytes[50..66] bytes[44..50] bytes[43]
    if error == "INVALID_ARGUMENT": throw "BLE_INVALID_BOND_RECORD"
    if error: throw error
    return Candidate bytes[4..20] local peer --authenticated=(bytes[3] == 1)
