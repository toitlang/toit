// Copyright (C) 2026 Toit contributors.
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

import ..gdb.src.gdb as gdb
import .target as target

/**
Adapts a stopped GDB Remote Serial Protocol connection to a decoder target.

The caller owns the RSP transport and supplies the exact memory map and Toit
  interpretation separately when constructing an inspector.
*/
class GdbTarget implements target.MutableTarget:
  client_/gdb.Client
  id/string
  regions/List
  stop-context_/Map

  constructor .client_ --.id --.regions --stop-context/Map={:}:
    stop-context_ = stop-context

  read address/int length/int -> ByteArray:
    if not allows address length: throw "TARGET_READ_OUTSIDE_MEMORY_MAP"
    return client_.read-memory address length

  allows address/int length/int -> bool:
    if length <= 0: return false
    regions.do: | region/target.MemoryRegion |
      if address >= region.address and address + length <= region.end-address:
        return true
    return false

  write address/int bytes/ByteArray -> none:
    if bytes.is-empty or not allows address bytes.size:
      throw "TARGET_WRITE_OUTSIDE_MEMORY_MAP"
    client_.write-memory address bytes

  stop-context -> Map:
    return stop-context_

  observation -> Map:
    return stop-context_
