// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for installing container images in flash, and
  stopping and starting containers based on them.
*/

import uuid
import system.api.containers show ContainerServiceClient
import system.services show ServiceResourceProxy

_client_ /ContainerServiceClient ::= ContainerServiceClient.lookup

images -> List:
  return _client_.list_images

start id/uuid.Uuid -> int:
  return _client_.start_image id

uninstall id/uuid.Uuid -> none:
  _client_.uninstall_image id

class ContainerImageWriter extends ServiceResourceProxy:
  size/int ::= ?

  constructor .size:
    super _client_ (_client_.image_writer_open size)

  write bytes/ByteArray -> none:
    _client_.image_writer_write handle_ bytes

  commit -> uuid.Uuid:
    return _client_.image_writer_commit handle_
