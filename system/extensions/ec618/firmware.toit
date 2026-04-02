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

import system.api.firmware show FirmwareService
import system.services show ServiceProvider ServiceResource
import system.base.firmware show FirmwareServiceProviderBase FirmwareWriter

import ec618

import encoding.ubjson

class FirmwareServiceProvider extends FirmwareServiceProviderBase:
  config_/Map ::= {:}

  constructor:
    catch: config_ = ubjson.decode firmware-embedded-config_
    super "system/firmware/ec618" --major=0 --minor=1

  // EC618 has no dual-partition scheme, so validation is never pending.
  is-validation-pending -> bool:
    return false

  // EC618 has no dual-partition scheme, so rollback is not possible.
  is-rollback-possible -> bool:
    return false

  validate -> bool:
    return true

  rollback -> none:
    // Not supported on EC618.

  upgrade -> none:
    // Trigger a reboot to apply the update.
    ec618.deep-sleep (Duration --ms=10)

  config-ubjson -> ByteArray:
    return firmware-embedded-config_.copy

  config-entry key/string -> any:
    return config_.get key

  content -> ByteArray?:
    // Return null to let the caller use the firmware content
    // provided by the underlying system.
    return null

  uri -> string?:
    return "flash:ec618"

  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    return FirmwareWriter_ this client from to

/**
The $FirmwareWriter_ uses the OTA support of the EC618 to update
  the firmware image. After writing and committing the firmware,
  a reboot (via deep sleep) applies the update.
*/
class FirmwareWriter_ extends ServiceResource implements FirmwareWriter:
  static REQUIRED-WRITE-ALIGNMENT ::= 16
  static PAGE-SIZE ::= 4096

  buffer_/ByteArray? := ByteArray PAGE-SIZE
  fullness_/int := 0
  written_/int := ?

  constructor provider/ServiceProvider client/int from/int to/int:
    ota-begin_ from to
    written_ = from
    super provider client

  write bytes/ByteArray -> int:
    return write_ bytes.size: | index from to |
      buffer_.replace index bytes from to

  pad size/int value/int -> int:
    return write_ size: | index from to |
      buffer_.fill --from=index --to=(index + to - from) value

  write_ size [block] -> int:
    fullness-flush := (round-up (written_ + 1) PAGE-SIZE) - written_
    return List.chunk-up 0 size (fullness-flush - fullness_) PAGE-SIZE: | from to |
      block.call fullness_ from to
      fullness_ += to - from
      if fullness_ == fullness-flush:
        unflushed := flush
        assert: unflushed == 0
        fullness-flush = PAGE-SIZE

  flush -> int:
    flushable := round-down fullness_ REQUIRED-WRITE-ALIGNMENT
    if flushable == 0: return 0
    written_ = ota-write_ buffer_[..flushable]
    buffer_.replace 0 buffer_ flushable fullness_
    fullness_ -= flushable
    return fullness_

  commit checksum/ByteArray? -> none:
    flush
    ota-end_ written_ checksum
    buffer_ = null

  on-closed -> none:
    if not buffer_: return
    ota-end_ 0 null
    buffer_ = null

// ----------------------------------------------------------------------------

ota-begin_ from/int to/int -> none:
  #primitive.ec618.ota-begin

ota-write_ bytes/ByteArray -> int:
  #primitive.ec618.ota-write

ota-end_ size/int checksum/ByteArray? -> none:
  #primitive.ec618.ota-end

firmware-embedded-config_ -> any:
  #primitive.programs-registry.config
