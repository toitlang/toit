// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import uuid
import system.services show ServiceClient
import system.containers show ContainerImage

interface ContainerService:
  static UUID  /string ::= "358ee529-45a4-409e-8fab-7a28f71e5c51"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 6

  static FLAG_RUN_BOOT     /int ::= 1 << 0
  static FLAG_RUN_CRITICAL /int ::= 1 << 1

  list_images -> List
  static LIST_IMAGES_INDEX /int ::= 0

  load_image id/uuid.Uuid -> int?
  static LOAD_IMAGE_INDEX /int ::= 1

  start_container handle/int arguments/any -> none
  static START_CONTAINER_INDEX /int ::= 7

  stop_container handle/int -> none
  static STOP_CONTAINER_INDEX /int ::= 6

  uninstall_image id/uuid.Uuid -> none
  static UNINSTALL_IMAGE_INDEX /int ::= 2

  image_writer_open size/int -> int
  static IMAGE_WRITER_OPEN_INDEX /int ::= 3

  image_writer_write handle/int bytes/ByteArray -> none
  static IMAGE_WRITER_WRITE_INDEX /int ::= 4

  image_writer_commit handle/int flags/int data/int -> uuid.Uuid
  static IMAGE_WRITER_COMMIT_INDEX /int ::= 5

class ContainerServiceClient extends ServiceClient implements ContainerService:
  constructor --open/bool=true:
    super --open=open

  open -> ContainerServiceClient?:
    return (open_ ContainerService.UUID ContainerService.MAJOR ContainerService.MINOR) and this

  list_images -> List:
    array := invoke_ ContainerService.LIST_IMAGES_INDEX null
    return List array.size / 4:
      cursor := it * 4
      ContainerImage
          --id=uuid.Uuid array[cursor]
          --name=array[cursor + 1]
          --flags=array[cursor + 2]
          --data=array[cursor + 3]

  load_image id/uuid.Uuid -> int?:
    return invoke_ ContainerService.LOAD_IMAGE_INDEX id.to_byte_array

  start_container handle/int arguments/any -> none:
    invoke_ ContainerService.START_CONTAINER_INDEX [handle, arguments]

  stop_container handle/int -> none:
    invoke_ ContainerService.STOP_CONTAINER_INDEX handle

  uninstall_image id/uuid.Uuid -> none:
    invoke_ ContainerService.UNINSTALL_IMAGE_INDEX id.to_byte_array

  image_writer_open size/int -> int:
    return invoke_ ContainerService.IMAGE_WRITER_OPEN_INDEX size

  image_writer_write handle/int bytes/ByteArray -> none:
    invoke_ ContainerService.IMAGE_WRITER_WRITE_INDEX [handle, bytes]

  image_writer_commit handle/int flags/int data/int -> uuid.Uuid:
    return uuid.Uuid (invoke_ ContainerService.IMAGE_WRITER_COMMIT_INDEX [handle, flags, data])
