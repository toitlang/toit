// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for updating the firmware.
*/

import system.api.firmware show FirmwareServiceClient
import system.services show ServiceResourceProxy

_client_ /FirmwareServiceClient? ::= (FirmwareServiceClient --no-open).open

/**
The configuration of the current firmware.
*/
config /FirmwareConfig ::= FirmwareConfig_

/**
The content bytes of the current firmware.
*/
content -> FirmwareContent?:
  if not _client_: return null
  backing := _client_.content
  return backing ? FirmwareContent_ backing : null

/**
Returns whether the currently executing firmware is
  pending validation.

Firmware that is not validated automatically rolls back to
  the previous firmware on reboot, so if validation is
  pending, you must $validate the firmware if you want
  to reboot into the current firmware.
*/
is_validation_pending -> bool:
  if not _client_: return false
  return _client_.is_validation_pending

/**
Returns whether another firmware is installed and
  can be rolled back to.
*/
is_rollback_possible -> bool:
  if not _client_: return false
  return _client_.is_rollback_possible

/**
Validates the current firmware and tells the
  bootloader to boot from it in the future.

Returns true if the validation was successful and
  false if the validation was unsuccesful or just
  not needed ($is_validation_pending is false).
*/
validate -> bool:
  if not _client_: throw "UNSUPPORTED"
  return _client_.validate

/**
Reboots into the firmware installed through
  the latest committed firmware writing.
  See $FirmwareWriter.commit.

Throws an exception if the upgraded firmware is
  invalid or not present.
*/
upgrade -> none:
  if not _client_: throw "UNSUPPORTED"
  _client_.upgrade

/**
Rolls back the firmware to a previously installed
  firmware and reboots.

Throws an exception if the previous firmware is
  invalid or not present.
*/
rollback -> none:
  if not _client_: throw "UNSUPPORTED"
  _client_.rollback

/**
The $FirmwareWriter supports incrementally building up a
  new firmware in a separate partition.

Once the firmware has been built, the firmware must be
  committed before a call to $upgrade or a reboot will
  start running it.

It is common that newly installed firmware boots with
  pending validation; see $is_validation_pending.
*/
class FirmwareWriter extends ServiceResourceProxy:
  constructor from/int to/int:
    if not _client_: throw "UNSUPPORTED"
    super _client_ (_client_.firmware_writer_open from to)

  write bytes/ByteArray -> none:
    _client_.firmware_writer_write handle_ bytes

  pad size/int --value/int=0 -> none:
    _client_.firmware_writer_pad handle_ size value

  commit --checksum/ByteArray?=null -> none:
    _client_.firmware_writer_commit handle_ checksum

interface FirmwareConfig:
  /**
  Returns the configuration entry for the given $key, or
    null if the $key isn't present in the configuration.
  */
  operator [] key/string -> any

  /**
  Returns the UBJSON encoded configuration.
  */
  ubjson -> ByteArray

interface FirmwareContent:
  /**
  Returns the size of the firmware content in bytes.
  */
  size -> int

  /**
  Returns the byte at the given $index.
  */
  operator [] index/int -> int

  /**
  ...
  */
  read from/int to/int --out/ByteArray --index/int -> none

class FirmwareConfig_ implements FirmwareConfig:
  operator [] key/string -> any:
    return _client_.config_entry key

  ubjson -> ByteArray:
    return _client_.config_ubjson

class FirmwareContent_ implements FirmwareContent:
  backing_/ByteArray
  constructor .backing_:

  size -> int:
    return backing_.size

  operator [] index/int -> int:
    return backing_[index]

  read from/int to/int --out/ByteArray --index/int -> none:
    out.replace index backing_ from to
