// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface FirmwareService:
  static SELECTOR ::= ServiceSelector
      --uuid="777096e8-05bc-4af7-919e-5ba696549bd5"
      --major=0
      --minor=6

  is-validation-pending -> bool
  static IS-VALIDATION-PENDING-INDEX /int ::= 0

  is-rollback-possible -> bool
  static IS-ROLLBACK-POSSIBLE-INDEX /int ::= 1

  validate -> bool
  static VALIDATE-INDEX /int ::= 2

  upgrade -> none
  static UPGRADE-INDEX /int ::= 3

  rollback -> none
  static ROLLBACK-INDEX /int ::= 4

  config-ubjson -> ByteArray
  static CONFIG-UBJSON-INDEX ::= 8

  config-entry key/string -> any
  static CONFIG-ENTRY-INDEX /int ::= 9

  content -> ByteArray?
  static CONTENT-INDEX /int ::= 11

  uri -> string?
  static URI-INDEX /int ::= 13

  firmware-writer-open from/int to/int -> int
  static FIRMWARE-WRITER-OPEN-INDEX /int ::= 5

  firmware-writer-write handle/int bytes/ByteArray -> none
  static FIRMWARE-WRITER-WRITE-INDEX /int ::= 6

  firmware-writer-pad handle/int size/int value/int -> none
  static FIRMWARE-WRITER-PAD-INDEX /int ::= 10

  firmware-writer-flush handle/int -> int
  static FIRMWARE-WRITER-FLUSH-INDEX /int ::= 12

  firmware-writer-commit handle/int checksum/ByteArray? -> none
  static FIRMWARE-WRITER-COMMIT-INDEX /int ::= 7

class FirmwareServiceClient extends ServiceClient implements FirmwareService:
  static SELECTOR ::= FirmwareService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  is-validation-pending -> bool:
    return invoke_ FirmwareService.IS-VALIDATION-PENDING-INDEX null

  is-rollback-possible -> bool:
    return invoke_ FirmwareService.IS-ROLLBACK-POSSIBLE-INDEX null

  validate -> bool:
    return invoke_ FirmwareService.VALIDATE-INDEX null

  upgrade -> none:
    invoke_ FirmwareService.UPGRADE-INDEX null

  rollback -> none:
    invoke_ FirmwareService.ROLLBACK-INDEX null

  config-ubjson -> ByteArray:
    return invoke_ FirmwareService.CONFIG-UBJSON-INDEX null

  config-entry key/string -> any:
    return invoke_ FirmwareService.CONFIG-ENTRY-INDEX key

  content -> ByteArray?:
    return invoke_ FirmwareService.CONTENT-INDEX null

  uri -> string?:
    return invoke_ FirmwareService.URI-INDEX null

  firmware-writer-open from/int to/int -> int:
    return invoke_ FirmwareService.FIRMWARE-WRITER-OPEN-INDEX [from, to]

  firmware-writer-write handle/int bytes/ByteArray -> none:
    invoke_ FirmwareService.FIRMWARE-WRITER-WRITE-INDEX [handle, bytes]

  firmware-writer-pad handle/int size/int value/int -> none:
    invoke_ FirmwareService.FIRMWARE-WRITER-PAD-INDEX [handle, size, value]

  firmware-writer-flush handle/int -> int:
    return invoke_ FirmwareService.FIRMWARE-WRITER-FLUSH-INDEX handle

  firmware-writer-commit handle/int checksum/ByteArray? -> none:
    invoke_ FirmwareService.FIRMWARE-WRITER-COMMIT-INDEX [handle, checksum]
