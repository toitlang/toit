// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
Read-only EC618 dual-slot OTA state.

The EC618 AP image carries two VM slots, each $SLOT-SIZE bytes at XIP addresses
  supplied by the booted image's partition table. A power-fail-safe anchor
  record tracks separate known-good and trial configurations (partition table
  plus console UART), which slot is known-good, and which, if any, is on trial.

Firmware mutation is intentionally available only through the privileged
  `system.firmware` service. This library exposes slot identity, geometry, and
  trial state without giving application containers a raw erase/write API.
*/

/** Active-slot marker byte ('A' or 'B'). */
SLOT-A ::= 'A'
SLOT-B ::= 'B'

/**
Size of one VM slot, in bytes.

Read from the running firmware (the layout it was built for), so this
  library never carries its own copy of the flash geometry.
*/
SLOT-SIZE ::= slot-size_

slot-size_ -> int:
  #primitive.ec618.slot-size

/**
Returns the slot the runtime is currently executing from ($SLOT-A or
  $SLOT-B). During a trial this is the slot under test, not necessarily
  the known-good one recorded in the anchor record.
*/
active -> int:
  #primitive.ec618.slot-active

/**
Whether the running image is an unconfirmed trial — staged by a previous
  firmware update and not yet confirmed through `system.firmware`. If true,
  the image must validate through that service or it will be rolled back on
  the next reset.
*/
trial -> bool:
  #primitive.ec618.slot-trial
