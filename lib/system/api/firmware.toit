// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient

interface FirmwareService:
  static UUID  /string ::= "777096e8-05bc-4af7-919e-5ba696549bd5"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 5

  is_validation_pending -> bool
  static IS_VALIDATION_PENDING_INDEX /int ::= 0

  is_rollback_possible -> bool
  static IS_ROLLBACK_POSSIBLE_INDEX /int ::= 1

  validate -> bool
  static VALIDATE_INDEX /int ::= 2

  upgrade -> none
  static UPGRADE_INDEX /int ::= 3

  rollback -> none
  static ROLLBACK_INDEX /int ::= 4

  config_ubjson -> ByteArray
  static CONFIG_UBJSON_INDEX ::= 8

  config_entry key/string -> any
  static CONFIG_ENTRY_INDEX /int ::= 9

  content -> ByteArray?
  static CONTENT_INDEX /int ::= 11

  firmware_writer_open from/int to/int -> int
  static FIRMWARE_WRITER_OPEN_INDEX /int ::= 5

  firmware_writer_write handle/int bytes/ByteArray -> none
  static FIRMWARE_WRITER_WRITE_INDEX /int ::= 6

  firmware_writer_pad handle/int size/int value/int -> none
  static FIRMWARE_WRITER_PAD_INDEX /int ::= 10

  firmware_writer_flush handle/int -> int
  static FIRMWARE_WRITER_FLUSH_INDEX /int ::= 12

  firmware_writer_commit handle/int checksum/ByteArray? -> none
  static FIRMWARE_WRITER_COMMIT_INDEX /int ::= 7

class FirmwareServiceClient extends ServiceClient implements FirmwareService:
  constructor --open/bool=true:
    super --open=open

  open -> FirmwareServiceClient?:
    return (open_ FirmwareService.UUID FirmwareService.MAJOR FirmwareService.MINOR) and this

  is_validation_pending -> bool:
    return invoke_ FirmwareService.IS_VALIDATION_PENDING_INDEX null

  is_rollback_possible -> bool:
    return invoke_ FirmwareService.IS_ROLLBACK_POSSIBLE_INDEX null

  validate -> bool:
    return invoke_ FirmwareService.VALIDATE_INDEX null

  upgrade -> none:
    invoke_ FirmwareService.UPGRADE_INDEX null

  rollback -> none:
    invoke_ FirmwareService.ROLLBACK_INDEX null

  config_ubjson -> ByteArray:
    return invoke_ FirmwareService.CONFIG_UBJSON_INDEX null

  config_entry key/string -> any:
    return invoke_ FirmwareService.CONFIG_ENTRY_INDEX key

  content -> ByteArray?:
    return invoke_ FirmwareService.CONTENT_INDEX null

  firmware_writer_open from/int to/int -> int:
    return invoke_ FirmwareService.FIRMWARE_WRITER_OPEN_INDEX [from, to]

  firmware_writer_write handle/int bytes/ByteArray -> none:
    invoke_ FirmwareService.FIRMWARE_WRITER_WRITE_INDEX [handle, bytes]

  firmware_writer_pad handle/int size/int value/int -> none:
    invoke_ FirmwareService.FIRMWARE_WRITER_PAD_INDEX [handle, size, value]

  firmware_writer_flush handle/int -> int:
    return invoke_ FirmwareService.FIRMWARE_WRITER_FLUSH_INDEX handle

  firmware_writer_commit handle/int checksum/ByteArray? -> none:
    invoke_ FirmwareService.FIRMWARE_WRITER_COMMIT_INDEX [handle, checksum]
