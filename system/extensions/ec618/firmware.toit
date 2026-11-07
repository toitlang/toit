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

import system.services show ServiceResource
import system.base.firmware show FirmwareWriter

import ec618
import ec618.slot

import .firmware-writer show SlotFirmwareWriter SlotWriterBackend

import ..shared.firmware show EmbeddedFirmwareServiceProviderBase

slot-program-mode_ on/int -> none:
  #primitive.ec618.slot-program-mode

slot-mark-valid_ -> none:
  #primitive.ec618.slot-mark-valid

slot-mark-invalid-and-reset_ -> none:
  #primitive.ec618.slot-mark-invalid-and-reset

slot-reloc-begin_ table/ByteArray -> none:
  #primitive.ec618.slot-reloc-begin

slot-reloc-resume_ table/ByteArray -> none:
  #primitive.ec618.slot-reloc-resume

slot-read-inactive_ offset/int bytes/ByteArray -> none:
  #primitive.ec618.slot-inactive-read

slot-reloc-end_ -> none:
  #primitive.ec618.slot-reloc-end

slot-erase-inactive-sector_ offset/int -> none:
  #primitive.ec618.slot-inactive-erase

slot-write-inactive_ offset/int bytes/ByteArray -> none:
  #primitive.ec618.slot-inactive-write

slot-stage_ -> none:
  #primitive.ec618.slot-stage

class FirmwareServiceProvider extends EmbeddedFirmwareServiceProviderBase:
  writer_/FirmwareWriter_? := null
  opening_/bool := false

  constructor:
    super "system/firmware/ec618"

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
    slot-mark-valid_
    return true

  rollback -> none:
    slot-mark-invalid-and-reset_  // Does not return — resets to the good slot.

  upgrade -> none:
    // The new slot was staged by FirmwareWriter_.commit; reboot into it.
    // TODO(kasper): Before resetting, shut down other containers and system
    // services, including network connections, properly.
    ec618.reset

  uri -> string?:
    return "flash:ec618"

  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    if writer_ or opening_: throw "ALREADY_IN_USE"
    // Firmware-sector program/erase mode and relocation are global too. Enter
    // program mode before publishing the resource and unwind it if resource
    // construction/registration fails. The modem stays on: with a matched CP
    // the flash is CP-safe, and a cellular OTA needs the link up.
    // Rehashing a resumed prefix can yield before the resource is registered.
    // Reserve ownership throughout construction as well as its whole lifetime.
    opening_ = true
    programming := false
    opened := false
    try:
      slot-program-mode_ 1
      programming = true
      writer := FirmwareWriter_ this client from to
      writer_ = writer
      opened = true
      return writer
    finally:
      try:
        if not opened and programming:
          try:
            slot-reloc-end_
          finally:
            slot-program-mode_ 0
      finally:
        opening_ = false

  on-writer-closed_ writer/FirmwareWriter_ -> none:
    if writer_ == writer: writer_ = null

// Owns the global native relocation context until explicit close or client death.
class FirmwareWriter_ extends ServiceResource implements FirmwareWriter:
  writer_/SlotFirmwareWriter
  service_/FirmwareServiceProvider

  constructor .service_ client/int from/int to/int:
    writer_ = SlotFirmwareWriter (NativeSlotWriterBackend_) from to
    super service_ client

  write bytes/ByteArray -> int:
    return writer_.write bytes

  pad size/int value/int -> int:
    return writer_.pad size value

  flush -> int:
    return writer_.flush

  commit checksum/ByteArray? -> none:
    writer_.commit checksum

  on-closed -> none:
    try:
      writer_.close
    finally:
      try:
        slot-program-mode_ 0
      finally:
        service_.on-writer-closed_ this

class NativeSlotWriterBackend_ implements SlotWriterBackend:
  slot-size -> int:
    return slot.SLOT-SIZE

  begin table/ByteArray --resume/bool -> none:
    if resume: slot-reloc-resume_ table
    else: slot-reloc-begin_ table

  read offset/int bytes/ByteArray -> none:
    slot-read-inactive_ offset bytes

  erase offset/int -> none:
    slot-erase-inactive-sector_ offset

  write offset/int bytes/ByteArray -> none:
    slot-write-inactive_ offset bytes

  end -> none:
    slot-reloc-end_

  stage -> none:
    slot-stage_
