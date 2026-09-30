// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .central show Central Link
import .security-state show SecurityState

/**
The interface of a connection's security owner.

An $Owner is the object that the link's ATT client or GATT server hands
  incoming SMP PDUs to ($Owner.receive) and asks about the link's security
  ($SecurityState). One owner belongs to one connection lifetime and is
  closed with it. `security.Pairing` (fresh pairing), `bond-resume.Resume`
  (a stored bond) and `bond-registry.Bonding` (pairing that persists its
  bond) implement it.
*/

/** Owns security policy and SMP dispatch for one connection lifetime. */
interface Owner extends SecurityState:
  matches host/Central link/Link -> bool
  receive bytes/ByteArray -> none
  /**
  As the peripheral, asks the central for security with a Security Request:
    to pair, or to encrypt with the bond this owner holds. Does nothing on a
    central link or when the link is already secured.
  */
  request-security -> none
  close -> none
