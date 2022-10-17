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

import esp32
import encoding.ubjson

class FirmwareServiceDefinition extends ServiceDefinition implements FirmwareService:
  config_/Map ::= {:}

  constructor:
    catch: config_ = ubjson.decode firmware_embedded_config_
    super "system/firmware/esp32" --major=0 --minor=1
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

  is_validation_pending -> bool:
    return (ota_state_ & OTA_STATE_VALIDATION_PENDING_) != 0

  is_rollback_possible -> bool:
    return (ota_state_ & OTA_STATE_ROLLBACK_POSSIBLE_) != 0

  validate -> bool:
    return ota_validate_

  rollback -> none:
    ota_rollback_

  upgrade -> none:
    // TODO(kasper): Verify that we have a new firmware installed?
    // TODO(kasper): Don't just reboot from here. Shut down the
    // system properly instead.
    esp32.deep_sleep (Duration --ms=10)

  config_ubjson -> ByteArray:
    // TODO(kasper): We have to copy this for now, because we
    // cannot transfer a non-disposable byte array across the
    // RPC boundary just yet.
    return firmware_embedded_config_.copy

  config_entry key/string -> any:
    return config_.get key

  firmware_writer_open from/int to/int -> int:
    unreachable  // TODO(kasper): Nasty.

  firmware_writer_open client/int from/int to/int -> ServiceResource:
    return FirmwareWriter this client from to

  firmware_writer_write writer/FirmwareWriter bytes/ByteArray -> none:
    writer.write bytes

  firmware_writer_pad writer/FirmwareWriter size/int value/int -> none:
    writer.pad size value

  firmware_writer_commit writer/FirmwareWriter checksum/ByteArray? -> none:
    writer.commit checksum

/**
The $FirmwareWriter uses the OTA support of the ESP32 to let you
  update the firmware image. After writing and commiting the firmware,
  you must reboot (use deep_sleep) for the update to take effect.
*/
class FirmwareWriter extends ServiceResource:
  buffer_/ByteArray? := ByteArray 4096
  fullness_/int := 0
  written_/int := ?

  constructor service/ServiceDefinition client/int from/int to/int:
    ota_begin_ from to
    written_ = from
    super service client

  write bytes/ByteArray from=0 to=bytes.size -> int:
    return List.chunk_up from to (buffer_.size - fullness_) buffer_.size: | from to chunk |
      buffer_.replace fullness_ bytes from to
      fullness_ += chunk
      if fullness_ == buffer_.size:
        written_ = ota_write_ buffer_
        fullness_ = 0

  pad size/int value/int -> int:
    return List.chunk_up 0 size (buffer_.size - fullness_) buffer_.size: | from to chunk |
      end := fullness_ + chunk
      buffer_.fill --from=fullness_ --to=end value
      fullness_ = end
      if fullness_ == buffer_.size:
        written_ = ota_write_ buffer_
        fullness_ = 0

  commit checksum/ByteArray? -> none:
    if fullness_ != 0:
      written_ = ota_write_ buffer_[..fullness_]
      fullness_ = 0
    // Always commit. Always.
    ota_end_ written_ checksum
    buffer_ = null

  on_closed -> none:
    if not buffer_: return
    ota_end_ 0 null  // Ensure that the OTA process is cleared so a new one can start.
    buffer_ = null

// ----------------------------------------------------------------------------

ota_begin_ from/int to/int -> none:
  #primitive.esp32.ota_begin

ota_write_ bytes/ByteArray -> int:
  #primitive.esp32.ota_write

/// If size is non-zero, checks the new partition and sets the system to boot from it.
/// If checksum is non-null, uses that SHA256 hash to perform the check.
/// Also clears the current OTA process so a new one can start.
ota_end_ size/int checksum/ByteArray? -> none:
  #primitive.esp32.ota_end

OTA_STATE_VALIDATION_PENDING_ /int ::= 1 << 0
OTA_STATE_ROLLBACK_POSSIBLE_  /int ::= 1 << 1

ota_state_ -> int:
  #primitive.esp32.ota_state

ota_validate_ -> bool:
  #primitive.esp32.ota_validate

ota_rollback_ -> none:
  #primitive.esp32.ota_rollback

firmware_embedded_config_ -> any:
  #primitive.programs_registry.config
