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

import uuid

import .region
import .registry

FLASH_ALLOCATION_PROGRAM_TYPE ::= 0
FLASH_ALLOCATION_HEADER_SIZE ::= 48

class FlashAllocation implements FlashRegion:
  id/uuid.Uuid ::= ?
  offset/int ::= ?
  size_/int := ?
  type_/int := ?
  metadata_/ByteArray? := null

  constructor .offset .size_=-1 .type_=-1:
    id = uuid.Uuid (flash_registry_get_id_ offset)

  size -> int:
    if size_ == -1: size_ = flash_registry_get_size_ offset
    return size_

  type -> int:
    if type_ == -1: type_ = flash_registry_get_type_ offset
    return type_

  metadata -> ByteArray:
    if not metadata_: metadata_ = flash_registry_get_metadata_ offset
    return metadata_

// ----------------------------------------------------------------------------

flash_registry_get_id_ offset:
  #primitive.flash.get_id

flash_registry_get_type_ offset:
  #primitive.flash.get_type

flash_registry_get_metadata_ offset:
  #primitive.flash.get_meta_data

flash_registry_get_size_ offset:
  #primitive.flash.get_size
