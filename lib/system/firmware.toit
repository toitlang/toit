// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for updating the firmware.
*/

import system.api.firmware show FirmwareServiceClient
import system.services show ServiceResourceProxy

_client_ /FirmwareServiceClient ::= FirmwareServiceClient

class FirmwareWriter extends ServiceResourceProxy:
  constructor from/int to/int:
    super _client_ (_client_.firmware_writer_open from to)

  write bytes/ByteArray -> none:
    _client_.firmware_writer_write handle_ bytes

  commit --checksum/ByteArray?=null -> none:
    _client_.firmware_writer_commit handle_ checksum
