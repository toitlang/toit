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

/** Describes one readable address interval exposed by a target. */
interface MemoryRegion:
  id -> string
  name -> string
  address -> int
  size -> int
  end-address -> int
  kind -> string
  permissions -> string

/** Reads an allowed address range from frozen or live memory. */
interface MemoryReader:
  read address/int length/int -> ByteArray
  allows address/int length/int -> bool

/**
Provides access to a frozen artifact or a stopped live device.

Implementations decide whether $read returns stored bytes or fetches them
  incrementally.  A target deliberately contains no Toit interpretation data.
*/
interface Target extends MemoryReader:
  id -> string
  regions -> List

/** Adds normalized stop/capture evidence without adding Toit interpretation. */
interface ObservedTarget extends Target:
  observation -> Map

/** Adds debugger mutation and stopped-context access to a readable target. */
interface MutableTarget extends ObservedTarget:
  write address/int bytes/ByteArray -> none
  stop-context -> Map
