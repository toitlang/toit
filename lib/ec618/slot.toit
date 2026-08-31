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
EC618 dual-slot OTA helpers with esp-idf-style trial boot + rollback.

The EC618 AP image carries two VM slots, each $SLOT-SIZE bytes at XIP addresses
  supplied by the booted image's partition table. A power-fail-safe anchor
  record tracks separate known-good and trial configurations (partition table
  plus console UART), which slot is known-good, and which, if any, is on trial.

A newly written slot is *staged* as a trial rather than activated outright. On
  the next boot the dispatcher runs it once; the new image must $validate
  itself, otherwise the next reset automatically rolls back to the previous
  good slot. The typical OTA flow is:

```
offset := 0
while offset < slot.SLOT-SIZE:
  slot.erase-inactive-sector offset
  offset += slot.SECTOR-SIZE
offset = 0
while bytes := read-next-chunk:
  // Each chunk is 16-byte aligned and does not cross a sector boundary.
  slot.write-inactive offset bytes
  offset += bytes.size
slot.stage-and-reset
```

After the reboot the new image runs. Once it has confirmed itself healthy
  (for example after reconnecting to its backend) it must call:

```
slot.validate
```

If it never validates, the next reset rolls back to the previous slot,
  partition table, and console.
  $trial reports whether the running image is an unconfirmed trial.
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

Both $offset and the size of $bytes must be multiples of 16 (the flash segment
  size), and a write is limited to one 4 KB sector. Call
  $erase-inactive-sector first; flash NOR cells can only go 1 → 0 in a
  single write, so writing into a non-erased region silently produces
  garbage.
*/
write-inactive offset/int bytes/ByteArray -> none:
  #primitive.ec618.slot-inactive-write

/**
Arms relocate-on-write with the new image's SRL3 relocation $table and writes
  that table as the inactive slot's tail trailer.

The firmware is one position-independent image linked at a neutral base that
  is distinct from both slots. While armed, $write-inactive relocates the
  canonical bytes it is given onto the destination slot (the VM does the
  byte-level relocation in C++), so the caller only ever streams canonical
  image bytes — relocation is invisible. Both slots are localized by the
  difference between their table-provided XIP address and the neutral link
  base.

The table is also stored at the slot's tail (with its size as the slot's last
  word) so that, once this image boots as the active slot, the VM can recover
  its own table to un-relocate firmware reads. Call this after erasing the slot
  and while holding $program-mode (the trailer is written immediately). Call
  $reloc-end when the write completes. Chunks passed to $write-inactive are
  limited to one sector; full chunks are sector-aligned, and only the final
  chunk may be shorter, so no relocation site straddles a chunk.
*/
reloc-begin table/ByteArray -> none:
  #primitive.ec618.slot-reloc-begin

/** Disarms relocate-on-write and releases the table. Idempotent. */
reloc-end -> none:
  #primitive.ec618.slot-reloc-end

/**
Stages the freshly-written inactive slot as a trial and resets the chip
  so it boots into that slot. Does not return.

The known-good slot/configuration is left unchanged; the new slot boots *on
  trial* with a cloned configuration.
  The dispatcher records that it has run the trial once, so a crashing or
  hanging image is automatically rolled back on the next reset. The new
  image must call $validate to keep the change permanent.

Caller is expected to have written and verified a valid VM image into
  the inactive slot first, and to already hold $program-mode (the receiver
  enables it around the slot erase/write).
*/
stage-and-reset -> none:
  #primitive.ec618.slot-stage-and-reset

/**
Stages the freshly-written inactive slot as a trial WITHOUT resetting.

Like $stage-and-reset but returns normally instead of rebooting — the reboot
  into the trial is triggered separately (the standard firmware flow stages in
  `FirmwareWriter.commit` and reboots later in `firmware.upgrade`). Caller must
  already hold $program-mode and have written + verified the slot.
*/
stage -> none:
  #primitive.ec618.slot-stage

/**
Confirms the slot the runtime is running from: promotes its partition table
  and console with it, then cancels the pending rollback. Call this once the
  new image has verified it is healthy. Returns normally (no reset).

A no-op-equivalent when not running a trial (it simply re-asserts the
  current slot as known-good).
*/
validate -> none:
  #primitive.ec618.slot-mark-valid

/**
Rejects the pending trial and resets back to the previous known-good slot,
  partition table, and console (esp-idf's invalid-rollback-and-reboot). Use
  when the trial image detects it cannot function. Throws when the running
  image is not a trial; otherwise it does not return.
*/
mark-invalid-and-reset -> none:
  #primitive.ec618.slot-mark-invalid-and-reset

/**
Whether the running image is an unconfirmed trial — staged by a previous
  $stage-and-reset and not yet confirmed (see $validate). If true, the
  image must call $validate or it will be rolled back on the next reset.
*/
trial -> bool:
  #primitive.ec618.slot-trial

/**
Enters ($on != 0) or leaves the firmware-sector program/erase mode.

Required around any $erase-inactive-sector / $write-inactive into the
  protected AP-image region: without it those operations disrupt the modem
  CP and reset the chip almost immediately. Wraps the SDK's
  `fotaNvmNfsPeInit` (`luat_flash_ctrl_fw_sectors`).
*/
program-mode on/int -> none:
  #primitive.ec618.slot-program-mode
