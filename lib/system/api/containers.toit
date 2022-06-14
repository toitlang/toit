// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import uuid
import system.services show ServiceClient

interface ContainerService:
  static UUID  /string ::= "358ee529-45a4-409e-8fab-7a28f71e5c51"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 3

  static LIST_IMAGES_INDEX /int ::= 0
  list_images -> List

  static START_IMAGE_INDEX /int ::= 1
  start_image id/uuid.Uuid -> int?

  static UNINSTALL_IMAGE_INDEX /int ::= 2
  uninstall_image id/uuid.Uuid -> none

  static IMAGE_WRITER_OPEN_INDEX /int ::= 3
  image_writer_open size/int -> int

  static IMAGE_WRITER_WRITE_INDEX /int ::= 4
  image_writer_write handle/int bytes/ByteArray -> none

  static IMAGE_WRITER_COMMIT_INDEX /int ::= 5
  image_writer_commit handle/int -> uuid.Uuid

class ContainerServiceClient extends ServiceClient implements ContainerService:
  constructor --open/bool=true:
    super --open=open

  open -> ContainerServiceClient?:
    return (open_ ContainerService.UUID ContainerService.MAJOR ContainerService.MINOR) and this

  list_images -> List:
    array := invoke_ ContainerService.LIST_IMAGES_INDEX null
    return List array.size: uuid.Uuid array[it]

  start_image id/uuid.Uuid -> int?:
    return invoke_ ContainerService.START_IMAGE_INDEX id.to_byte_array

  uninstall_image id/uuid.Uuid -> none:
    invoke_ ContainerService.UNINSTALL_IMAGE_INDEX id.to_byte_array

  image_writer_open size/int -> int:
    return invoke_ ContainerService.IMAGE_WRITER_OPEN_INDEX size

  image_writer_write handle/int bytes/ByteArray -> none:
    invoke_ ContainerService.IMAGE_WRITER_WRITE_INDEX [handle, bytes]

  image_writer_commit handle/int -> uuid.Uuid:
    return uuid.Uuid (invoke_ ContainerService.IMAGE_WRITER_COMMIT_INDEX handle)
