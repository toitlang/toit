// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import uuid
import system.services show ServiceClient

interface FirmwareService:
  static UUID  /string ::= "777096e8-05bc-4af7-919e-5ba696549bd5"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static FIRMWARE_WRITER_OPEN_INDEX /int ::= 0
  firmware_writer_open from/int to/int -> int

  static FIRMWARE_WRITER_WRITE_INDEX /int ::= 1
  firmware_writer_write handle/int bytes/ByteArray -> none

  static FIRMWARE_WRITER_COMMIT_INDEX /int ::= 2
  firmware_writer_commit handle/int checksum/ByteArray? -> none

class FirmwareServiceClient extends ServiceClient implements FirmwareService:
  constructor --open/bool=true:
    super --open=open

  open -> FirmwareServiceClient?:
    return (open_ FirmwareService.UUID FirmwareService.MAJOR FirmwareService.MINOR) and this

  firmware_writer_open from/int to/int -> int:
    return invoke_ FirmwareService.FIRMWARE_WRITER_OPEN_INDEX [from, to]

  firmware_writer_write handle/int bytes/ByteArray -> none:
    invoke_ FirmwareService.FIRMWARE_WRITER_WRITE_INDEX [handle, bytes]

  firmware_writer_commit handle/int checksum/ByteArray? -> none:
    invoke_ FirmwareService.FIRMWARE_WRITER_COMMIT_INDEX [handle, checksum]
