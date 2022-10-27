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
...
*/
map --from/int=0 --to/int?=null [block] -> none:
  mapping/FirmwareMapping_? := null
  if _client_:
    data := firmware_map_ _client_.content
    if data:
      if not to: to = data.size
      if (0 <= from <= to) and (to <= data.size):
        mapping = FirmwareMapping_ data from (to - from)
  try:
    block.call mapping
  finally:
    if mapping: firmware_unmap_ mapping.data_

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

  flush -> none:
    _client_.firmware_writer_flush handle_

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

interface FirmwareMapping:
  /**
  Returns the size of the mapped firmware in bytes.
  */
  size -> int

  /**
  Returns the byte at the given $index.
  */
  operator [] index/int -> int

  /**
  ...
  */
  operator [..] --from/int=0 --to/int=size -> FirmwareMapping

  /**
  ...
  */
  copy from/int to/int --into/ByteArray -> none

// -------------------------------------------------------------------------

class FirmwareConfig_ implements FirmwareConfig:
  operator [] key/string -> any:
    return _client_.config_entry key

  ubjson -> ByteArray:
    return _client_.config_ubjson

class FirmwareMapping_ implements FirmwareMapping:
  data_/ByteArray
  offset_/int
  size/int
  constructor .data_ .offset_=0 .size=data_.size:

  operator [] index/int -> int:
    #primitive.core.firmware_mapping_at

  operator [..] --from/int=0 --to/int=size -> FirmwareMapping:
    return FirmwareMapping_ data_ (offset_ + from) (to - from)

  copy from/int to/int --into/ByteArray -> none:
    // TODO(kasper): Validate
    hunk := to - from
    // ...
    align := (from + offset_) & 3
    if align > 0: align = 4 - align
    prefix := min align hunk
    prefix.repeat: into[it] = this[from + it]
    from += prefix
    if from >= to: return
    // Handle suffix.
    suffix := min ((to + offset_) & 3) (hunk - prefix)
    to -= suffix
    suffix.repeat: into[hunk - suffix + it] = this[to + it]
    if from >= to: return
    // Copy the remaning bits using a block copy.
    copy_block_ from to into prefix

  copy_block_ from/int to/int into/ByteArray index/int -> none:
    #primitive.core.firmware_mapping_copy

firmware_map_ data/ByteArray? -> ByteArray?:
  #primitive.core.firmware_map

firmware_unmap_ data/ByteArray -> none:
  #primitive.core.firmware_unmap
