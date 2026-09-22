// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

/**
An owned bond inventory record without key material.

Addresses are public or static identity addresses in HCI byte order. The stored
  authentication flag describes pairing history, not an active connection or
  proof that the peer still has the bond. Slot numbers can be reused after
  revocation; retaining this record does not reserve or authorize a slot.
*/
class BondInfo:
  slot/int
  local-address_/ByteArray
  local-address-type/int
  peer-address_/ByteArray
  peer-address-type/int
  authenticated/bool
  revision_/ByteArray?

  constructor .slot local-address/ByteArray .local-address-type
      peer-address/ByteArray .peer-address-type .authenticated --revision/ByteArray?=null:
    if not 0 <= slot < 255 or local-address.size != 6 or peer-address.size != 6 or
        not 0 <= local-address-type <= 1 or not 0 <= peer-address-type <= 1:
      throw "INVALID_ARGUMENT"
    if revision and revision.size != 16: throw "INVALID_ARGUMENT"
    revision_ = revision and revision.copy
    local-address_ = local-address.copy
    peer-address_ = peer-address.copy

  /** Returns an independent copy of the local identity address. */
  local-address -> ByteArray: return local-address_.copy

  /** Returns an independent copy of the peer identity address. */
  peer-address -> ByteArray: return peer-address_.copy

  /** Returns an optional opaque inventory revision for conditional revocation. */
  revision -> ByteArray?: return revision_ and revision_.copy
