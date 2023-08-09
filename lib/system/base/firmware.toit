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
import system.services show ServiceHandler ServiceProvider ServiceResource

abstract class FirmwareServiceProviderBase extends ServiceProvider
    implements FirmwareService ServiceHandler:
  constructor name/string --major/int --minor/int:
    super name --major=major --minor=minor
    provides FirmwareService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == FirmwareService.IS-VALIDATION-PENDING-INDEX:
      return is-validation-pending
    if index == FirmwareService.IS-ROLLBACK-POSSIBLE-INDEX:
      return is-rollback-possible
    if index == FirmwareService.VALIDATE-INDEX:
      return validate
    if index == FirmwareService.UPGRADE-INDEX:
      return upgrade
    if index == FirmwareService.ROLLBACK-INDEX:
      return rollback
    if index == FirmwareService.CONFIG-UBJSON-INDEX:
      return config-ubjson
    if index == FirmwareService.CONFIG-ENTRY-INDEX:
      return config-entry arguments
    if index == FirmwareService.CONTENT-INDEX:
      return content
    if index == FirmwareService.URI-INDEX:
      return uri
    if index == FirmwareService.FIRMWARE-WRITER-OPEN-INDEX:
      return firmware-writer-open client arguments[0] arguments[1]
    if index == FirmwareService.FIRMWARE-WRITER-WRITE-INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware-writer-write writer arguments[1]
    if index == FirmwareService.FIRMWARE-WRITER-PAD-INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware-writer-pad writer arguments[1] arguments[2]
    if index == FirmwareService.FIRMWARE-WRITER-FLUSH-INDEX:
      writer ::= (resource client arguments) as FirmwareWriter
      return firmware-writer-flush writer
    if index == FirmwareService.FIRMWARE-WRITER-COMMIT-INDEX:
      writer ::= (resource client arguments[0]) as FirmwareWriter
      return firmware-writer-commit writer arguments[1]
    unreachable

  abstract is-validation-pending -> bool
  abstract is-rollback-possible -> bool

  abstract validate -> bool
  abstract rollback -> none
  abstract upgrade -> none

  abstract config-ubjson -> ByteArray
  abstract config-entry key/string -> any

  abstract content -> ByteArray?
  abstract uri -> string?

  firmware-writer-open from/int to/int -> int:
    unreachable  // TODO(kasper): Nasty.

  abstract firmware-writer-open client/int from/int to/int -> FirmwareWriter

  firmware-writer-write writer/FirmwareWriter bytes/ByteArray -> none:
    writer.write bytes

  firmware-writer-pad writer/FirmwareWriter size/int value/int -> none:
    writer.pad size value

  firmware-writer-flush writer/FirmwareWriter -> int:
    return writer.flush

  firmware-writer-commit writer/FirmwareWriter checksum/ByteArray? -> none:
    writer.commit checksum

interface FirmwareWriter:
  write bytes/ByteArray -> int
  pad size/int value/int -> int
  flush -> int
  commit checksum/ByteArray? -> none
