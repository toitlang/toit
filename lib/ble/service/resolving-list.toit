// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Identity records for the provider's resolving-list hook and ble.v2.linux.open.

Controller configuration belongs to the private host implementation.
*/

/** One bonded peer: its identity address (HCI order) and IRK (most significant byte first). */
class Entry:
  address-type/int
  address/ByteArray
  irk/ByteArray

  constructor --.address-type --.address --.irk:
    if not 0 <= address-type <= 1 or address.size != 6 or irk.size != 16: throw "INVALID_ARGUMENT"
