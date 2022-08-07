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
Returns whether another firmware is installed and can be
  rolled back to.
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
Rolls back the firmware to a previously installed
  firmware and reboots.

Throws an exception if the previous firmware is invalid
  or not present.
*/
rollback -> none:
  if not _client_: throw "UNSUPPORTED"
  _client_.rollback

/**
The $FirmwareWriter supports incrementally building up a
  new firmware in a separate partition.

Once the firmware has been built, the firmware must be
  committed before a reboot will start running it.

It is common that newly installed firmware boots with
  pending validation; see $is_validation_pending.
*/
class FirmwareWriter extends ServiceResourceProxy:
  constructor from/int to/int:
    if not _client_: throw "UNSUPPORTED"
    super _client_ (_client_.firmware_writer_open from to)

  write bytes/ByteArray -> none:
    _client_.firmware_writer_write handle_ bytes

  commit --checksum/ByteArray?=null -> none:
    _client_.firmware_writer_commit handle_ checksum
