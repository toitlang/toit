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

FLASH_REGISTRY_PAGE_SIZE ::= 4096

class FlashRegistry:
  static SCAN_HOLE_ ::= 0
  static SCAN_ALLOCATION_ ::= 1

  allocations_/Map ::= {:}  // Map<uuid.Uuid, FlashAllocation>
  holes_/List? := null      // List<FlashHole_>

  constructor.scan:
    // Scan the flash and keep all allocations found.
    holes_ = scan_

  // Iterate through the allocations.
  do [block] -> none:
    allocations_.do --values block

  // Reserves a region in the flash.
  reserve size/int --attempt_rescan=true -> FlashReservation?:
    size = (size + FLASH_REGISTRY_PAGE_SIZE - 1) & (-FLASH_REGISTRY_PAGE_SIZE)
    holes := holes_.filter: it.size >= size
    if holes.is_empty:
      if not attempt_rescan: return null
      holes_ = scan_
      return reserve size --attempt_rescan=false
    // Pick at suitable hole and return the offset for it.
    slot/FlashHole_ := holes[random holes.size]
    result := slot.offset
    // Make sure we can erase the slot before we return it.
    if (flash_registry_erase_ result size) < size: throw "Unable to erase flash at $result"
    // Remember to adjust the hole slot so that future calls to this method
    // will not return an overlapping region.
    slot.offset += size
    slot.size -= size
    return FlashReservation result size

  // Frees a previously allocated region in the flash.
  free allocation/FlashAllocation -> none:
    allocations_.remove allocation.id
    // Erasing the first page removes the full header. This is enough
    // to fully invalidate the allocation.
    flash_registry_erase_ allocation.offset FLASH_REGISTRY_PAGE_SIZE

  // Scan through the flash and update the given allocations map to reflect that
  // actual allocations found. If an allocation exists before and after the scan, we
  // make sure to keep the same allocation object, so existing references to it
  // remain valid.
  scan_ -> List:
    found := {:}
    holes := []
    offset := -1
    while true:
      offset = flash_registry_next_ offset
      if not offset: break
      info := flash_registry_info_ offset
      flag := info & 3
      if flag == SCAN_HOLE_:
        size := (info >> 2) * FLASH_REGISTRY_PAGE_SIZE
        holes.add (FlashHole_ offset size)
      else if flag == SCAN_ALLOCATION_:
        size := (info >> 10) * FLASH_REGISTRY_PAGE_SIZE
        type := (info >> 2) & 0xFF
        allocation/FlashAllocation := FlashAllocation offset size type
        found[allocation.id] = allocation
    // Update the allocations map, keeping existing allocation objects.
    update_allocations_ found
    // Return the coalesced list of holes.
    return coalesce_ holes

  static coalesce_ holes/List -> List:
    if holes.is_empty: return holes
    holes.sort --in_place: | a b | a.offset - b.offset
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

  update_allocations_ found/Map -> none:
    // Use an extra list for the allocations to be freed because we cannot update
    // the allocations map while iterating over it.
    freed := []
    allocations_.do: | id/uuid.Uuid allocation/FlashAllocation |
      if found.contains id:
        found.remove id
      else:
        freed.add allocation
    // Remove any old freed allocations.
    freed.do: free it
    // Add the new allocations found.
    found.do: | id/uuid.Uuid allocation/FlashAllocation |
      allocations_[id] = allocation

class FlashHole_:
  offset/int := ?
  size/int := ?
  constructor .offset .size:

// ----------------------------------------------------------------------------

flash_registry_info_ offset:
  #primitive.flash.info

flash_registry_next_ offset:
  #primitive.flash.next

flash_registry_erase_ offset size:
  #primitive.flash.erase

