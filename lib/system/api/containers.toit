// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import uuid
import system.services show ServiceClient

interface ContainersService:
  static NAME  /string ::= "system/containers"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static LIST_IMAGES_INDEX /int ::= 0
  list_images -> List

  static START_IMAGE_INDEX /int ::= 1
  start_image id/uuid.Uuid -> int?

  static UNINSTALL_IMAGE_INDEX /int ::= 2
  uninstall_image id/uuid.Uuid -> none

class ContainersServiceClient extends ServiceClient implements ContainersService:
  constructor.lookup name=ContainersService.NAME major=ContainersService.MAJOR minor=ContainersService.MINOR:
    super.lookup name major minor

  list_images -> List:
    array := invoke_ ContainersService.LIST_IMAGES_INDEX null
    return List array.size: uuid.Uuid array[it]

  start_image id/uuid.Uuid -> int?:
    return invoke_ ContainersService.START_IMAGE_INDEX id.to_byte_array

  uninstall_image id/uuid.Uuid -> none:
    invoke_ ContainersService.UNINSTALL_IMAGE_INDEX id.to_byte_array
