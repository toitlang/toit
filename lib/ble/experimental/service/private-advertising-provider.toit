// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import ..privacy as privacy
import .advertising-provider as advertising

/**
Provides non-connectable advertising with timed resolvable private addresses.

The provider owns a copy of its IRK. Its creator must obtain that key from the
  deployment's identity storage; this class does not persist or distribute keys.
  The default interval is the fifteen-minute recommendation in Core Vol 3,
  Part C, 10.7.3 and 17. Advertising pauses briefly while changing the address.

Applications must avoid identifying data in their advertisements if they require
  unlinkability. This class does not change advertising payloads or provide
  privacy for connectable advertising, scanning or established links.
*/
abstract class Provider extends advertising.Provider:
  irk_/ByteArray
  interval_/Duration
  previous_/ByteArray? := null

  constructor irk/ByteArray --rotation-interval/Duration=(Duration --s=900):
    if irk.size != 16 or rotation-interval.in-us <= 0: throw "INVALID_ARGUMENT"
    irk_ = irk.copy
    interval_ = rotation-interval
    super

  address-rotation-interval -> Duration?: return interval_

  local-random-address -> ByteArray?:
    while true:
      address := privacy.generate irk_
      if address == previous_: continue
      previous_ = address.copy
      return address
