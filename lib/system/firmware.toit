// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for updating the firmware.
*/

import system.api.firmware show FirmwareServiceClient
import system.services show ServiceResourceProxy

_client_ /FirmwareServiceClient? ::= (FirmwareServiceClient).open
    --if_absent=: null

/**
The configuration of the current firmware.
*/
config /FirmwareConfig ::= FirmwareConfig_

/**
Map the current firmware into memory, so the content
  bytes of it can be accessed.

The mapping is only valid while executing the given
  $block.
*/
map --from/int=0 --to/int?=null [block] -> none:
  mapping/FirmwareMapping_? := null
  if _client_:
    data := firmware_map_ _client_.content
    if data:
      if not to: to = data.size
      if 0 <= from <= to <= data.size:
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
  false if the validation was unsuccessful or just
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
  static BUFFER_SIZE_ ::= 4096
  buffer_/ByteArray? := null
  buffered_/int := 0

  constructor from/int to/int:
    if not _client_: throw "UNSUPPORTED"
    super _client_ (_client_.firmware_writer_open from to)

  /**
  Write the $bytes into the target firmware.

  If $bytes is an external byte array, the byte array will
    be transferred without copying and thus neutered as
    part of the call. Such a byte array will be turned into
    an empty byte array.
  */
  write bytes/ByteArray -> none:
    size := bytes.size
    if buffer := buffer_:
      buffered := buffered_
      free := BUFFER_SIZE_ - buffered
      if size <= free:
        buffer.replace buffered bytes 0 size
        buffered_ += size
        return
      // Fill buffer and flush it.
      buffer.replace buffered bytes 0 free
      flush_ buffer BUFFER_SIZE_
      // Adjust remaining bytes.
      size -= free
      bytes = bytes[free..]

    if size >= BUFFER_SIZE_:
      _client_.firmware_writer_write handle_ bytes
    else:
      buffer := ByteArray BUFFER_SIZE_
      buffer.replace 0 bytes 0 size
      buffer_ = buffer
      buffered_ = size

  /**
  Copy all bytes from $mapping into the target firmware.

  As the copying progresses and writes to the firmware
    are performed, the $progress block is invoked and
    passed the non-accumulated number of bytes written.
  */
  copy mapping/FirmwareMapping [progress] -> none:
    flush_
    List.chunk_up 0 mapping.size BUFFER_SIZE_: | from to size |
      buffer := ByteArray BUFFER_SIZE_
      mapping.copy from to --into=buffer
      if size < BUFFER_SIZE_:
        buffer_ = buffer
        buffered_ = size
      else:
        _client_.firmware_writer_write handle_ buffer
      progress.call size

  pad size/int --value/int=0 -> none:
    flush_
    _client_.firmware_writer_pad handle_ size value

  flush -> int:
    flush_
    return _client_.firmware_writer_flush handle_

  commit --checksum/ByteArray?=null -> none:
    flush_
    _client_.firmware_writer_commit handle_ checksum

  flush_ buffer/ByteArray?=buffer_ buffered/int=buffered_ -> none:
    if not buffer: return
    _client_.firmware_writer_write handle_ buffer[..buffered]
    buffer_ = null
    buffered_ = 0

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
  Returns a slice of the firmware mapping.
  */
  operator [..] --from/int=0 --to/int=size -> FirmwareMapping

  /**
  Copies a section of the mapped firmware into the $into byte
    array.
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
    if not 0 <= from <= to <= size: throw "OUT_OF_BOUNDS"
    return FirmwareMapping_ data_ (offset_ + from) (to - from)

  copy from/int to/int --into/ByteArray -> none:
    if not 0 <= from <= to <= size: throw "OUT_OF_BOUNDS"
    // Determine if we can do an aligned block copy taking
    // the offset into account.
    offset := offset_
    block_from := min to ((round_up (from + offset) 4) - offset)
    block_to := (round_down (to + offset) 4) - offset
    // Copy the bytes in up to three chunks.
    cursor := copy_range_ from block_from into 0
    if block_from < block_to:
      cursor = copy_block_ block_from block_to into cursor
    else:
      block_to = block_from
    copy_range_ block_to to into cursor

  copy_range_ from/int to/int into/ByteArray index/int -> int:
    while from < to: into[index++] = this[from++]
    return index

  copy_block_ from/int to/int into/ByteArray index/int -> int:
    #primitive.core.firmware_mapping_copy

firmware_map_ data/ByteArray? -> ByteArray?:
  #primitive.core.firmware_map

firmware_unmap_ data/ByteArray -> none:
  #primitive.core.firmware_unmap
