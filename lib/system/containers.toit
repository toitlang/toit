// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for installing container images in flash, and
  stopping and starting containers based on them.
*/

import uuid
import system.api.containers show ContainersService ContainersServiceClient

client_ /ContainersService ::= ContainersServiceClient.lookup

images -> List:
  return client_.list_images

start id/uuid.Uuid -> int:
  return client_.start_image id

uninstall id/uuid.Uuid -> none:
  client_.uninstall_image id

/*
class ContainerImageWriter extends rpc.CloseableProxy:
  size/int ::= ?

  constructor .size:
    super (rpc.invoke RPC_CONTAINERS_IMAGE_WRITER_OPEN size)

  write bytes/ByteArray -> none:
    rpc.invoke RPC_CONTAINERS_IMAGE_WRITER_WRITE [handle_, bytes]

  commit -> uuid.Uuid:
    return uuid.Uuid (rpc.invoke RPC_CONTAINERS_IMAGE_WRITER_COMMIT [handle_])

  close_rpc_selector_ -> int:
    return RPC_CONTAINERS_IMAGE_WRITER_CLOSE
*/