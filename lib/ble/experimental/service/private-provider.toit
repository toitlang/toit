// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import ..privacy as privacy
import .pairing-provider as pairing-provider

/**
A GATT provider with optional fresh pairing and an RPA per peripheral session.

The provider owns a copy of its 16-byte identity resolving key. Its creator must
  obtain that key from the deployment's identity storage; this class does not
  persist or distribute keys. Importing the ordinary GATT provider does not
  import this policy or the address-generation module.

The existing session advertises for at most sixty seconds, then either connects
  or closes its controller. This policy never changes an active link's address.
  It rotates at the next session, not during a continuously advertising service.
*/
abstract class Provider extends pairing-provider.Provider:
  irk_/ByteArray
  previous_/ByteArray? := null

  constructor irk/ByteArray:
    if irk.size != 16: throw "INVALID_ARGUMENT"
    irk_ = irk.copy
    super

  local-random-address -> ByteArray?:
    while true:
      address := privacy.generate irk_
      if address == previous_: continue
      previous_ = address.copy
      return address
