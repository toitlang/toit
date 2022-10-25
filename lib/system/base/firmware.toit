// Copyright (C) 2022 Toitware ApS.
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
import system.services show ServiceDefinition ServiceResource

abstract class FirmwareServiceDefinitionBase extends ServiceDefinition implements FirmwareService:
  constructor name/string --major/int --minor/int:
    super name --major=major --minor=minor
    provides FirmwareService.UUID FirmwareService.MAJOR FirmwareService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == FirmwareService.IS_VALIDATION_PENDING_INDEX:
      return is_validation_pending
    if index == FirmwareService.IS_ROLLBACK_POSSIBLE_INDEX:
      return is_rollback_possible
    if index == FirmwareService.VALIDATE_INDEX:
      return validate
    if index == FirmwareService.UPGRADE_INDEX:
      return upgrade
    if index == FirmwareService.ROLLBACK_INDEX:
      return rollback
    if index == FirmwareService.CONFIG_UBJSON_INDEX:
      return config_ubjson
    if index == FirmwareService.CONFIG_ENTRY_INDEX:
      return config_entry arguments
    if index == FirmwareService.CONTENT_INDEX:
      return content
    if index == FirmwareService.FIRMWARE_WRITER_OPEN_INDEX:
      return firmware_writer_open client arguments[0] arguments[1]
    if index == FirmwareService.FIRMWARE_WRITER_WRITE_INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware_writer_write writer arguments[1]
    if index == FirmwareService.FIRMWARE_WRITER_PAD_INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware_writer_pad writer arguments[1] arguments[2]
    if index == FirmwareService.FIRMWARE_WRITER_COMMIT_INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware_writer_commit writer arguments[1]
    unreachable

  abstract is_validation_pending -> bool
  abstract is_rollback_possible -> bool

  abstract validate -> bool
  abstract rollback -> none
  abstract upgrade -> none

  abstract config_ubjson -> ByteArray
  abstract config_entry key/string -> any

  abstract content -> ByteArray?

  firmware_writer_open from/int to/int -> int:
    unreachable  // TODO(kasper): Nasty.

  abstract firmware_writer_open client/int from/int to/int -> FirmwareWriter

  firmware_writer_write writer/FirmwareWriter bytes/ByteArray -> none:
    writer.write bytes

  firmware_writer_pad writer/FirmwareWriter size/int value/int -> none:
    writer.pad size value

  firmware_writer_commit writer/FirmwareWriter checksum/ByteArray? -> none:
    writer.commit checksum

interface FirmwareWriter:
  write bytes/ByteArray -> int
  pad size/int value/int -> int
  commit checksum/ByteArray? -> none
