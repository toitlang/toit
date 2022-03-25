// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for installing container images in flash, and
  stopping and starting containers based on them.
*/

import rpc
import uuid

RPC_CONTAINERS_LIST_IMAGES     ::= 100
RPC_CONTAINERS_START_IMAGE     ::= 101
RPC_CONTAINERS_UNINSTALL_IMAGE ::= 102

RPC_CONTAINERS_IMAGE_WRITER_OPEN   := 103
RPC_CONTAINERS_IMAGE_WRITER_WRITE  := 104
RPC_CONTAINERS_IMAGE_WRITER_COMMIT := 105
RPC_CONTAINERS_IMAGE_WRITER_CLOSE  := 106

images -> List:
  array := rpc.invoke RPC_CONTAINERS_LIST_IMAGES null
  return List array.size: uuid.Uuid array[it]

start id/uuid.Uuid -> int:
  return rpc.invoke RPC_CONTAINERS_START_IMAGE id.to_byte_array

uninstall id/uuid.Uuid -> none:
  rpc.invoke RPC_CONTAINERS_UNINSTALL_IMAGE id.to_byte_array

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
