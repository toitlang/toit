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

import system.api.firmware show FirmwareService
import system.services show ServiceProvider ServiceResource
import system.base.firmware show FirmwareServiceProviderBase FirmwareWriter

import ec618
import ec618.slot

import crypto.sha256 show Sha256
import encoding.ubjson
import io show Buffer LITTLE-ENDIAN

class FirmwareServiceProvider extends FirmwareServiceProviderBase:
  config_/Map ::= {:}

  constructor:
    catch: config_ = ubjson.decode firmware-embedded-config_
    super "system/firmware/ec618" --major=0 --minor=1

  // A freshly written slot boots on trial; the running image must validate
  // itself or the next reset rolls back. So validation is pending exactly when
  // the runtime is executing an unconfirmed trial.
  is-validation-pending -> bool:
    return slot.trial

  // While on an unconfirmed trial the previous (known-good) slot is the
  // rollback target. Once validated the old slot may be overwritten by a later
  // update, so we only advertise rollback during the trial window.
  is-rollback-possible -> bool:
    return slot.trial

  validate -> bool:
    slot.validate
    return true

  rollback -> none:
    slot.mark-invalid-and-reset  // Does not return — resets to the good slot.

  upgrade -> none:
    // The new slot was staged by FirmwareWriter_.commit; reboot into it.
    // firmware.upgrade exits the VM via deep sleep; the EC618 run loop
    // (toit_ec618.cc) then hard-resets into the staged slot.
    ec618.deep-sleep (Duration --ms=10)

  config-ubjson -> ByteArray:
    return firmware-embedded-config_.copy

  config-entry key/string -> any:
    return config_.get key

  content -> ByteArray?:
    // Return null so the caller maps the running firmware via firmware.map.
    return null

  uri -> string?:
    return "flash:ec618"

  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    return FirmwareWriter_ this client from to

/**
Writes a new firmware image to the INACTIVE VM slot via relocate-on-write.

The stream is the standard CANONICAL firmware image, table-first:

```
[ table-size : u32 ][ SRL3 reloc table ][ VM body + extension ]
```

The writer accumulates the leading `[ size ][ table ]` and arms relocation
  ($slot.reloc-begin, which also lays the slot's self-locating tail trailer),
  then streams the body+extension into the slot — the VM relocates each chunk
  onto the destination slot transparently, so this code never sees slot
  addresses. $commit verifies the canonical SHA-256 and stages the slot as a
  trial; `firmware.upgrade` reboots into it, and the new image must
  `firmware.validate` or the next reset rolls back.

Runs in the system (firmware service) process, so it may call the PRIVILEGED
  slot primitives.
*/
class FirmwareWriter_ extends ServiceResource implements FirmwareWriter:
  static SECTOR ::= slot.SECTOR-SIZE  // 4 KB erase unit.
  static SEGMENT ::= 16               // Flash write granularity.

  // Header phase: accumulate [ size:4 ][ table:N ] before arming relocation.
  header_/Buffer? := Buffer
  header-length_/int := 0
  table-length_/int := -1             // N; known once 4 bytes are in.
  armed_/bool := false

  // Body phase: buffer a sector, flush it whole, lazily erase ahead of writes.
  body_/ByteArray := ByteArray SECTOR
  fullness_/int := 0
  slot-offset_/int := 0               // Next body offset within the slot.
  erased-until_/int := 0              // Sectors [0, erased-until_) are erased.

  sha_/Sha256 := Sha256               // Over the whole canonical image.
  staged_/bool := false

  constructor provider/ServiceProvider client/int from/int to/int:
    // Firmware-sector program/erase mode is required for any write into the
    // protected AP-image region (the inactive slot). The modem stays on — with
    // a matched CP the flash is CP-safe, and a cellular OTA needs the link up.
    slot.program-mode 1
    super provider client

  write bytes/ByteArray -> int:
    sha_.add bytes
    consume_ bytes 0 bytes.size
    return bytes.size

  pad size/int value/int -> int:
    chunk := ByteArray (min size SECTOR)
    chunk.fill value
    remaining := size
    while remaining > 0:
      n := min remaining chunk.size
      sha_.add chunk 0 n
      consume_ chunk 0 n
      remaining -= n
    return size

  // Routes `bytes[from..to)`: header bytes accumulate until the table is
  // complete (then relocation is armed), everything after is body.
  consume_ bytes/ByteArray from/int to/int -> none:
    while from < to and not armed_:
      header_.write-byte bytes[from]
      from++
      header-length_++
      if header-length_ == 4:
        table-length_ = LITTLE-ENDIAN.uint32 header_.bytes 0
      else if table-length_ >= 0 and header-length_ == 4 + table-length_:
        full := header_.bytes
        slot.reloc-begin full[4 .. 4 + table-length_]
        armed_ = true
        header_ = null
    if from < to: write-body_ bytes from to

  write-body_ bytes/ByteArray from/int to/int -> none:
    while from < to:
      n := min (body_.size - fullness_) (to - from)
      body_.replace fullness_ bytes from (from + n)
      fullness_ += n
      from += n
      if fullness_ == body_.size: flush-full-sector_

  // Writes one full (sector-aligned) sector and advances. Sector alignment
  // guarantees no relocation site straddles the write window.
  flush-full-sector_ -> none:
    ensure-erased_ (slot-offset_ + SECTOR)
    slot.write-inactive slot-offset_ body_
    slot-offset_ += SECTOR
    fullness_ = 0

  ensure-erased_ end/int -> none:
    target := round-up end SECTOR
    while erased-until_ < target:
      slot.erase-inactive-sector erased-until_
      erased-until_ += SECTOR

  // Only full sectors are written eagerly; the sub-sector remainder is held and
  // written by $commit. So flush just reports the still-buffered byte count.
  flush -> int:
    return fullness_

  commit checksum/ByteArray? -> none:
    if not armed_: throw "firmware: incomplete image (no relocation table)"
    // Write the final sub-sector remainder, padded to the segment size. The pad
    // lands in the slot's free region (past the populated bytes) and is not part
    // of the canonical image.
    if fullness_ > 0:
      padded := round-up fullness_ SEGMENT
      body_.fill --from=fullness_ --to=padded 0
      ensure-erased_ (slot-offset_ + padded)
      slot.write-inactive slot-offset_ body_[..padded]
      slot-offset_ += fullness_
      fullness_ = 0
    digest := sha_.get
    if checksum and checksum != digest:
      slot.reloc-end
      throw "firmware: checksum mismatch"
    slot.reloc-end
    slot.stage  // Stage as a trial; firmware.upgrade reboots into it.
    staged_ = true

  on-closed -> none:
    if not staged_: slot.reloc-end
    slot.program-mode 0

// ----------------------------------------------------------------------------

firmware-embedded-config_ -> any:
  #primitive.programs-registry.config
