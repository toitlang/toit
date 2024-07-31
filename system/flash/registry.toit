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

import .allocation
import .reservation

FLASH-REGISTRY-PAGE-SIZE-LOG2 ::= 12
FLASH-REGISTRY-PAGE-SIZE ::= 1 << FLASH-REGISTRY-PAGE-SIZE-LOG2

class FlashRegistry:
  static SCAN-HOLE_ ::= 0
  static SCAN-ALLOCATION_ ::= 1

  allocations_/Map ::= {:}  // Map<int, FlashAllocation>
  holes_/List? := null      // List<FlashHole_>

  constructor.scan:
    // Scan the flash and keep all allocations found.
    holes_ = scan_

  // Iterate through the allocations.
  do [block] -> none:
    allocations_.do --values block

  // Reserves a region in the flash.
  reserve size/int --attempt-rescan=true -> FlashReservation?:
    size = (size + FLASH-REGISTRY-PAGE-SIZE - 1) & (-FLASH-REGISTRY-PAGE-SIZE)
    holes := holes_.filter: it.size >= size
    if holes.is-empty:
      if not attempt-rescan: return null
      holes_ = scan_
      return reserve size --attempt-rescan=false
    // Pick at suitable hole and return the offset for it.
    slot/FlashHole_ := holes[random holes.size]
    result := slot.offset
    // Make sure we can erase the slot before we return it.
    if (flash-registry-erase_ result size) < size: throw "Unable to erase flash at $result"
    // Remember to adjust the hole slot so that future calls to this method
    // will not return an overlapping region.
    slot.offset += size
    slot.size -= size
    return FlashReservation result size

  allocate reservation/FlashReservation -> FlashAllocation
      --type/int
      --id/uuid.Uuid
      --metadata/ByteArray
      --content/ByteArray=#[]:
    try:
      offset := reservation.offset
      size := reservation.size
      flash-registry-allocate_ offset size type id.to-byte-array metadata content
      allocation := FlashAllocation offset size
      allocations_[offset] = allocation
      return allocation
    finally:
      reservation.close

  // Frees a previously allocated region in the flash.
  free allocation/FlashAllocation -> none:
    allocations_.remove allocation.offset
    // Erasing the first page removes the full header. This is enough
    // to fully invalidate the allocation.
    flash-registry-erase_ allocation.offset FLASH-REGISTRY-PAGE-SIZE

  // Scan through the flash and update the given allocations map to reflect that
  // actual allocations found. If an allocation exists before and after the scan, we
  // make sure to keep the same allocation object, so existing references to it
  // remain valid.
  scan_ -> List:
    found := {:}
    holes := []
    offset/int? := -1
    while true:
      offset = flash-registry-next_ offset
      if not offset: break
      info := flash-registry-info_ offset
      flag := info & 3
      if flag == SCAN-HOLE_:
        size := (info >> 2) * FLASH-REGISTRY-PAGE-SIZE
        holes.add (FlashHole_ offset size)
      else if flag == SCAN-ALLOCATION_:
        size := (info >> 10) * FLASH-REGISTRY-PAGE-SIZE
        type := (info >> 2) & 0xFF
        allocation/FlashAllocation := FlashAllocation offset size
        found[allocation.offset] = allocation
    // Update the allocations map, keeping existing allocation objects.
    update-allocations_ found
    // Return the coalesced list of holes.
    return coalesce_ holes

  static coalesce_ holes/List -> List:
    if holes.is-empty: return holes
    holes.sort --in-place: | a b | a.offset - b.offset
    // Run through the sorted list of holes and build a new list
    // with the coalesced holes.
    last/FlashHole_ := holes[0]
    result := [last]
    for i := 1; i < holes.size; i++:
      hole := holes[i]
      if last.offset + last.size == hole.offset:
        last.size += hole.size
      else:
        result.add hole
        last = hole
    return result

  update-allocations_ found/Map -> none:
    // Use an extra list for the allocations to be freed because we cannot update
    // the allocations map while iterating over it.
    freed := []
    allocations_.do: | offset/int allocation/FlashAllocation |
      if found.contains offset:
        found.remove offset
      else:
        freed.add allocation
    // Remove any old freed allocations.
    freed.do: free it
    // Add the new allocations found.
    found.do: | offset/int allocation/FlashAllocation |
      allocations_[offset] = allocation

class FlashHole_:
  offset/int := ?
  size/int := ?
  constructor .offset .size:

// ----------------------------------------------------------------------------

flash-registry-info_ offset:
  #primitive.flash.info

flash-registry-next_ offset:
  #primitive.flash.next

flash-registry-erase_ offset size:
  #primitive.flash.erase

flash-registry-allocate_ offset size type id metadata content:
  #primitive.flash.allocate
