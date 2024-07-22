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

import uuid show *

import .region
import .registry

FLASH-ALLOCATION-TYPE-PROGRAM ::= 0
FLASH-ALLOCATION-TYPE-REGION  ::= 1

FLASH-ALLOCATION-HEADER-MARKER-SIZE   ::= 4
FLASH-ALLOCATION-HEADER-ME-SIZE       ::= 4
FLASH-ALLOCATION-HEADER-ID-SIZE       ::= Uuid.SIZE
FLASH-ALLOCATION-HEADER-METADATA-SIZE ::= 5
FLASH-ALLOCATION-HEADER-TYPE-SIZE     ::= 1
FLASH-ALLOCATION-HEADER-SIZE-SIZE     ::= 2
FLASH-ALLOCATION-HEADER-UUID-SIZE     ::= Uuid.SIZE

FLASH-ALLOCATION-HEADER-MARKER-OFFSET ::=
    0
FLASH-ALLOCATION-HEADER-ME-OFFSET ::=
    FLASH-ALLOCATION-HEADER-MARKER-OFFSET + FLASH-ALLOCATION-HEADER-MARKER-SIZE
FLASH-ALLOCATION-HEADER-ID-OFFSET ::=
    FLASH-ALLOCATION-HEADER-ME-OFFSET + FLASH-ALLOCATION-HEADER-ME-SIZE
FLASH-ALLOCATION-HEADER-METADATA-OFFSET ::=
    FLASH-ALLOCATION-HEADER-ID-OFFSET + FLASH-ALLOCATION-HEADER-ID-SIZE
FLASH-ALLOCATION-HEADER-TYPE-OFFSET ::=
    FLASH-ALLOCATION-HEADER-METADATA-OFFSET + FLASH-ALLOCATION-HEADER-METADATA-SIZE
FLASH-ALLOCATION-HEADER-SIZE-OFFSET ::=
    FLASH-ALLOCATION-HEADER-TYPE-OFFSET + FLASH-ALLOCATION-HEADER-TYPE-SIZE
FLASH-ALLOCATION-HEADER-UUID-OFFSET ::=
    FLASH-ALLOCATION-HEADER-SIZE-OFFSET + FLASH-ALLOCATION-HEADER-SIZE-SIZE
FLASH-ALLOCATION-HEADER-SIZE ::=
    FLASH-ALLOCATION-HEADER-UUID-OFFSET + FLASH-ALLOCATION-HEADER-UUID-SIZE

class FlashAllocation implements FlashRegion:
  header-page_ ::= ?
  id/Uuid ::= ?
  offset/int ::= ?
  size_/int := ?

  constructor .offset .size_=-1:
    header-page_ = flash-registry-get-header-page_ offset
    from := FLASH-ALLOCATION-HEADER-ID-OFFSET
    to := from + FLASH-ALLOCATION-HEADER-ID-SIZE
    id = Uuid header-page_[from..to]

  size -> int:
    if size_ == -1: size_ = flash-registry-get-size_ offset
    return size_

  type -> int:
    return header-page_[FLASH-ALLOCATION-HEADER-TYPE-OFFSET]

  metadata -> ByteArray:
    from := FLASH-ALLOCATION-HEADER-METADATA-OFFSET
    to := from + FLASH-ALLOCATION-HEADER-METADATA-SIZE
    return header-page_[from..to]

  content -> ByteArray:
    return header-page_[FLASH-ALLOCATION-HEADER-SIZE..]

// ----------------------------------------------------------------------------

flash-registry-get-header-page_ offset:
  #primitive.flash.get-header-page

flash-registry-get-size_ offset:
  #primitive.flash.get-size
