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

FLASH_ALLOCATION_TYPE_PROGRAM ::= 0
FLASH_ALLOCATION_TYPE_REGION  ::= 1

FLASH_ALLOCATION_HEADER_MARKER_SIZE   ::= 4
FLASH_ALLOCATION_HEADER_ME_SIZE       ::= 4
FLASH_ALLOCATION_HEADER_ID_SIZE       ::= uuid.SIZE
FLASH_ALLOCATION_HEADER_METADATA_SIZE ::= 5
FLASH_ALLOCATION_HEADER_TYPE_SIZE     ::= 1
FLASH_ALLOCATION_HEADER_SIZE_SIZE     ::= 2
FLASH_ALLOCATION_HEADER_UUID_SIZE     ::= uuid.SIZE

FLASH_ALLOCATION_HEADER_MARKER_OFFSET ::=
    0
FLASH_ALLOCATION_HEADER_ME_OFFSET ::=
    FLASH_ALLOCATION_HEADER_MARKER_OFFSET + FLASH_ALLOCATION_HEADER_MARKER_SIZE
FLASH_ALLOCATION_HEADER_ID_OFFSET ::=
    FLASH_ALLOCATION_HEADER_ME_OFFSET + FLASH_ALLOCATION_HEADER_ME_SIZE
FLASH_ALLOCATION_HEADER_METADATA_OFFSET ::=
    FLASH_ALLOCATION_HEADER_ID_OFFSET + FLASH_ALLOCATION_HEADER_ID_SIZE
FLASH_ALLOCATION_HEADER_TYPE_OFFSET ::=
    FLASH_ALLOCATION_HEADER_METADATA_OFFSET + FLASH_ALLOCATION_HEADER_METADATA_SIZE
FLASH_ALLOCATION_HEADER_SIZE_OFFSET ::=
    FLASH_ALLOCATION_HEADER_TYPE_OFFSET + FLASH_ALLOCATION_HEADER_TYPE_SIZE
FLASH_ALLOCATION_HEADER_UUID_OFFSET ::=
    FLASH_ALLOCATION_HEADER_SIZE_OFFSET + FLASH_ALLOCATION_HEADER_SIZE_SIZE
FLASH_ALLOCATION_HEADER_SIZE ::=
    FLASH_ALLOCATION_HEADER_UUID_OFFSET + FLASH_ALLOCATION_HEADER_UUID_SIZE

class FlashAllocation implements FlashRegion:
  header_page_ ::= ?
  id/uuid.Uuid ::= ?
  offset/int ::= ?
  size_/int := ?

  constructor .offset .size_=-1:
    header_page_ = flash_registry_get_header_page_ offset
    from := FLASH_ALLOCATION_HEADER_ID_OFFSET
    to := from + FLASH_ALLOCATION_HEADER_ID_SIZE
    id = uuid.Uuid header_page_[from..to]

  size -> int:
    if size_ == -1: size_ = flash_registry_get_size_ offset
    return size_

  type -> int:
    return header_page_[FLASH_ALLOCATION_HEADER_TYPE_OFFSET]

  metadata -> ByteArray:
    from := FLASH_ALLOCATION_HEADER_METADATA_OFFSET
    to := from + FLASH_ALLOCATION_HEADER_METADATA_SIZE
    return header_page_[from..to]

  content -> ByteArray:
    return header_page_[FLASH_ALLOCATION_HEADER_SIZE..]

// ----------------------------------------------------------------------------

flash_registry_get_header_page_ offset:
  #primitive.flash.get_header_page

flash_registry_get_size_ offset:
  #primitive.flash.get_size
