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
EC618 dual-slot OTA helpers.

The EC618 AP image carries two VM slots — `.vm_a` and `.vm_b`, each
384 KB at fixed XIP addresses. A 1-byte marker (`.slot_marker`) picks
which slot the PLAT dispatcher in `toit_main.c` boots into on next
reset.

These helpers let a Toit container write a new VM image into the slot
that is currently inactive and then atomically swap the active-slot
byte. The typical OTA flow:

  // Erase the whole inactive slot, one sector at a time so the
  // PLAT watchdog can tick between calls.
  off := 0
  while off < slot.SLOT-SIZE:
    slot.erase-inactive-sector off
    off += slot.SECTOR-SIZE
  // Stream payload chunks (must be 16-byte aligned per the flash
  // segment size — the receiver tool batches naturally).
  off = 0
  while bytes := read-next-chunk:
    slot.write-inactive off bytes
    off += bytes.size
  slot.swap-and-reset              // does not return
*/

/** Active-slot marker byte ('A' or 'B'). */
SLOT-A ::= 'A'
SLOT-B ::= 'B'

/** Size of one VM slot, in bytes (384 KB). */
SLOT-SIZE ::= 0x60000

/**
Returns the active-slot byte the dispatcher will use on next boot.
Equal to either $SLOT-A or $SLOT-B; reads the value the current cold
boot found in `.slot_marker`.
*/
active -> int:
  #primitive.ec618.slot-active

/** Flash sector size, in bytes (4 KB). */
SECTOR-SIZE ::= 0x1000

/**
Erases one 4 KB sector inside the inactive slot, starting at $offset
(must be sector-aligned). Erasing the whole slot in one primitive
takes too long for the PLAT watchdog; call this sector by sector
from a loop instead.
*/
erase-inactive-sector offset/int -> none:
  #primitive.ec618.slot-inactive-erase

/**
Writes $bytes into the inactive slot at $offset.

Both $offset and $bytes.size must be multiples of 16 (the flash
segment size). Call $erase-inactive first; flash NOR cells can only
go 1 → 0 in a single write, so writing into a non-erased region
silently produces garbage.
*/
write-inactive offset/int bytes/ByteArray -> none:
  #primitive.ec618.slot-inactive-write

/**
Flips the active-slot marker (`A` → `B` or `B` → `A`) and resets the
chip so it boots from the freshly-written slot. Does not return; on
next boot the slot dispatcher reads the new marker value and calls
through that slot's entry pointer.

Caller is expected to have written and verified a valid VM image
into the inactive slot first. Swapping into an unflashed slot will
hard-fault on the next boot.
*/
swap-and-reset -> none:
  #primitive.ec618.slot-swap-and-reset

/**
Enters ($on != 0) or leaves the firmware-sector program/erase mode.

Required around any $erase-inactive-sector / $write-inactive into the
protected AP-image region: without it those operations disrupt the modem
CP and reset the chip almost immediately. Wraps the SDK's
`fotaNvmNfsPeInit` (`luat_flash_ctrl_fw_sectors`).
*/
program-mode on/int -> none:
  #primitive.ec618.slot-program-mode

/**
Sets modem functionality via the SDK's `appSetCFUN` ($fun; 0 turns the
modem/PS off). Returns the SDK result code.

The dual-slot OTA turns the modem off for the flash, because sustained
AP flash + UART activity with the modem on resets the chip after a few
seconds (an as-yet-unexplained CP real-time deadline).
*/
modem-set-function fun/int -> int:
  #primitive.ec618.modem-set-function
