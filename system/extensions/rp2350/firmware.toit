// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import system.services show ServiceResource
import system.base.firmware show FirmwareWriter
import crypto.sha256 show Sha256

import ..shared.firmware show EmbeddedFirmwareServiceProviderBase

SECTOR-SIZE_ ::= 4096

class FirmwareServiceProvider extends EmbeddedFirmwareServiceProviderBase:
  writer_/FirmwareWriter_? := null

  constructor:
    super "system/firmware/rp2350"

  is-validation-pending -> bool:
    return trial_

  is-rollback-possible -> bool:
    return trial_

  validate -> bool:
    validate_
    return true

  rollback -> none:
    rollback_

  upgrade -> none:
    upgrade_

  uri -> string?:
    return "flash:rp2350"

  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    if writer_: throw "ALREADY_IN_USE"
    if trial_: throw "PERMISSION_DENIED"
    // The stream is a complete SDK-produced raw image, linked at XIP_BASE.
    // Partial firmware/delta writes need a separate image reconstruction step.
    if from != 0 or not (SECTOR-SIZE_ <= to <= inactive-size_):
      throw "INVALID_ARGUMENT"
    writer := FirmwareWriter_ this client to
    writer_ = writer
    return writer

  on-writer-closed_ writer/FirmwareWriter_ -> none:
    if writer_ == writer: writer_ = null

/** Writes a complete hashed trial image into the inactive firmware slot. */
class FirmwareWriter_ extends ServiceResource implements FirmwareWriter:
  service_/FirmwareServiceProvider
  size_/int
  first_/ByteArray := ByteArray SECTOR-SIZE_ --initial=0xff
  buffer_/ByteArray := ByteArray SECTOR-SIZE_ --initial=0xff
  received_/int := 0
  fullness_/int := 0
  sha_/Sha256 := Sha256
  failed_/bool := false
  committed_/bool := false

  constructor .service_ client/int .size_:
    // Invalidate the previous inactive image before modifying any of its body.
    // The currently running image has already been validated.
    erase_ 0
    super service_ client

  check-open_ -> none:
    if is-closed or failed_ or committed_: throw "ALREADY_CLOSED"

  write bytes/ByteArray -> int:
    check-open_
    if bytes.size > size_ - received_: throw "OUT_OF_BOUNDS"
    failed_ = true
    sha_.add bytes
    from := 0
    while from < bytes.size:
      if received_ < SECTOR-SIZE_:
        count := min (SECTOR-SIZE_ - received_) (bytes.size - from)
        first_.replace received_ bytes from (from + count)
        from += count
        received_ += count
      else:
        count := min (SECTOR-SIZE_ - fullness_) (bytes.size - from)
        buffer_.replace fullness_ bytes from (from + count)
        fullness_ += count
        received_ += count
        from += count
        if fullness_ == SECTOR-SIZE_: flush-sector_
    failed_ = false
    return bytes.size

  pad size/int value/int -> int:
    check-open_
    if size < 0 or not (0 <= value <= 255): throw "INVALID_ARGUMENT"
    if size > size_ - received_: throw "OUT_OF_BOUNDS"
    chunk := ByteArray (min size SECTOR-SIZE_) --initial=value
    remaining := size
    while remaining > 0:
      count := min remaining chunk.size
      write chunk[..count]
      remaining -= count
    return size

  flush-sector_ -> none:
    offset := received_ - fullness_
    erase_ offset
    buffer_.fill --from=fullness_ 0xff
    write_ offset buffer_
    fullness_ = 0

  flush -> int:
    check-open_
    // Keep the boot header unpublished until checksum and length checks pass.
    return (min received_ SECTOR-SIZE_) + fullness_

  commit checksum/ByteArray? -> none:
    check-open_
    if received_ != size_: throw "firmware: incomplete image"
    failed_ = true
    if checksum and checksum != sha_.get: throw "firmware: checksum mismatch"
    if fullness_ != 0: flush-sector_
    // Native staging verifies before publishing the header. On rejection, invalidate its
    // header again so no future boot can accidentally select it.
    accepted := false
    try:
      stage_ size_ first_
      accepted = true
    finally:
      if not accepted: erase_ 0
    committed_ = true
    failed_ = false

  on-closed -> none:
    service_.on-writer-closed_ this

trial_ -> bool:
  #primitive.rp2350.is-trial

validate_ -> none:
  #primitive.rp2350.validate

rollback_ -> none:
  #primitive.rp2350.rollback

upgrade_ -> none:
  #primitive.rp2350.upgrade

inactive-size_ -> int:
  #primitive.rp2350.inactive-size

erase_ offset/int -> none:
  #primitive.rp2350.inactive-erase

write_ offset/int bytes/ByteArray -> none:
  #primitive.rp2350.inactive-write

stage_ size/int first/ByteArray -> none:
  #primitive.rp2350.stage
