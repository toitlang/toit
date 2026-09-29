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

/**
Decodes the memory captures written by `system.capture-memory`.

A capture is a sequence of text lines of the form "#TMC <base64>". The
  base64 payload consists of a sequence number (u32 LE), a UBJSON record, and
  a CRC-32 (u32 LE) of the preceding bytes. Everything else in the input (for
  example other console output) is ignored.

See src/memory_capture.cc for the record types.
*/

import crypto.crc
import encoding.base64
import encoding.ubjson
import io show LITTLE-ENDIAN

FORMAT-VERSION ::= 1

LINE-PREFIX ::= "#TMC "

HEADER-RECORD ::= 0
LAYOUT-RECORD ::= 1
STRUCT-TAG-NAMES-RECORD ::= 2
PROGRAM-RECORD ::= 3
CLASS-BITS-RECORD ::= 4
PROCESS-RECORD ::= 5
ROOTS-RECORD ::= 6
CHUNK-RECORD ::= 7
DATA-RECORD ::= 8
END-RECORD ::= 9
MALLOC-TAG-NAMES-RECORD ::= 10
SYSTEM-HEAP-RECORD ::= 11
MALLOC-RECORD ::= 12
CAPTURE-BLOCKS-RECORD ::= 13

TASK-ROOT ::= 0
GLOBAL-ROOT ::= 1
EXTERNAL-ROOT ::= 2

FINALIZER-ROOT ::= 3

ROOT-KIND-NAMES ::= ["task", "global", "external", "finalizer"]

/**
Decodes a single capture line.

Returns a list with the sequence number and the record, or null if the line
  doesn't contain a capture record. Throws if the record is corrupt.
*/
decode-line line/string -> List?:
  index := line.index-of LINE-PREFIX
  if index < 0: return null
  frame := base64.decode line[index + LINE-PREFIX.size..].trim
  if frame.size < 8: throw "malformed record"
  payload := frame[..frame.size - 4]
  if (crc.crc32 payload) != (LITTLE-ENDIAN.uint32 frame (frame.size - 4)):
    throw "checksum mismatch"
  return [LITTLE-ENDIAN.uint32 payload 0, ubjson.decode payload[4..]]

/** A block of the system (malloc) heap. */
class MallocBlock:
  address/int
  size/int
  tag/int
  /** The process that made the allocation, or on whose behalf it was made, or null. */
  process-id/int?

  constructor .address .size .tag .process-id:

  end -> int: return address + size

/** The size of a system heap, as reported by the allocator. */
class SystemHeap:
  name/string
  total/int
  free/int
  largest-free-block/int

  constructor .name .total .free .largest-free-block:

/** A program (the compiled code of a container) that runs in a process. */
class ProgramInfo:
  address/int
  uuid/ByteArray
  size/int
  bytecodes-address/int
  bytecodes-size/int
  class-bits/List
  /** The tagged values of null, true, and false. */
  null-value/int
  true-value/int
  false-value/int

  constructor .address .uuid .size .bytecodes-address .bytecodes-size class-count/int
      .null-value .true-value .false-value:
    class-bits = List class-count 0

  contains address/int -> bool:
    return this.address <= address < this.address + size

  uuid-string -> string:
    hex := List uuid.size: "$(%02x uuid[it])"
    return "$(hex[0..4].join "")-$(hex[4..6].join "")-$(hex[6..8].join "")-$(hex[8..10].join "")-$(hex[10..].join "")"

/** A root of a process: a task, a global variable, or an external root. */
class Root:
  kind/int
  index/int
  value/int

  constructor .kind .index .value:

  kind-name -> string: return ROOT-KIND-NAMES[kind]

class ProcessInfo:
  id/int
  group-id/int
  program-address/int
  priority/int
  heap-bytes/int
  external-bytes/int
  roots/List ::= []   // Of $Root.
  chunks/List ::= []  // Of $Chunk.

  constructor .id .group-id .program-address .priority .heap-bytes .external-bytes:

/** A chunk of a Toit heap, with its captured bytes. */
class Chunk:
  process-id/int
  address/int
  bytes/ByteArray

  constructor .process-id .address size/int:
    bytes = ByteArray size

  size -> int: return bytes.size
  end -> int: return address + bytes.size

  contains address/int -> bool:
    return this.address <= address < end

class Capture:
  version/string := ""
  platform/string := ""
  word-size/int := 4
  reason/string := ""
  layout/Map ::= {:}
  malloc-tag-names/List := []
  struct-tag-names/Map ::= {:}
  system-heaps/List ::= []    // Of $SystemHeap.
  malloc-blocks/List ::= []   // Of $MallocBlock.
  /** Addresses in the malloc blocks that the capture itself uses. */
  capture-addresses/List ::= []
  programs/Map ::= {:}        // From address to $ProgramInfo.
  processes/List ::= []       // Of $ProcessInfo.
  chunks/List ::= []          // Of $Chunk, sorted by address.
  /** Problems found while decoding. An empty list means the capture is complete. */
  problems/List ::= []

  /**
  Decodes the first capture in the given text.
  Lines that don't contain a capture record are ignored.
  */
  constructor.parse text/string:
    last-sequence := null
    text.split "\n": | line/string |
      if done_: continue.split
      decoded := null
      exception := catch: decoded = decode-line line
      if exception:
        problems.add "corrupt record: $exception"
        continue.split
      if not decoded: continue.split
      sequence := decoded[0]
      if last-sequence == null and sequence != 0:
        problems.add "missing records 0..$(sequence - 1)"
      if last-sequence != null and sequence <= last-sequence:
        // A second capture starts. Only decode the first one.
        done_ = true
        continue.split
      if last-sequence != null and sequence != last-sequence + 1:
        problems.add "missing records $(last-sequence + 1)..$(sequence - 1)"
      last-sequence = sequence
      exception = catch: decode_ decoded[1]
      if exception: problems.add "invalid record $sequence: $exception"
    if last-sequence == null: problems.add "no capture found"
    else if not has-end_: problems.add "capture is truncated"
    chunks.sort --in-place: | a b | a.address.compare-to b.address

  has-end_/bool := false
  done_/bool := false
  current-chunk_/Chunk? := null

  decode_ record/List -> none:
    type := record[0]
    if type == HEADER-RECORD:
      if record[1] != FORMAT-VERSION:
        throw "unsupported capture format version $record[1]"
      version = record[2]
      platform = record[3]
      word-size = record[4]
      reason = record[5]
    else if type == LAYOUT-RECORD:
      for i := 1; i < record.size; i += 2:
        layout[record[i]] = record[i + 1]
    else if type == MALLOC-TAG-NAMES-RECORD:
      malloc-tag-names = record[1..]
    else if type == STRUCT-TAG-NAMES-RECORD:
      for i := 1; i < record.size; i += 2:
        struct-tag-names[record[i]] = record[i + 1]
    else if type == SYSTEM-HEAP-RECORD:
      system-heaps.add (SystemHeap record[1] record[2] record[3] record[4])
    else if type == MALLOC-RECORD:
      decode-malloc-blocks_ record[1]
    else if type == CAPTURE-BLOCKS-RECORD:
      capture-addresses.add-all record[1..]
    else if type == PROGRAM-RECORD:
      program := ProgramInfo record[1] record[2] record[3] record[4] record[5] record[6] record[7] record[8] record[9]
      programs[program.address] = program
    else if type == CLASS-BITS-RECORD:
      program/ProgramInfo := programs[record[1]]
      first := record[2]
      bytes/ByteArray := record[3]
      for i := 0; i < bytes.size; i += 2:
        program.class-bits[first + i / 2] = LITTLE-ENDIAN.uint16 bytes i
    else if type == PROCESS-RECORD:
      processes.add (ProcessInfo record[1] record[2] record[3] record[4] record[5] record[6])
    else if type == ROOTS-RECORD:
      process := process-by-id record[1]
      kind := record[2]
      index := record[3]
      words/ByteArray := record[4]
      for i := 0; i < words.size; i += word-size:
        process.roots.add (Root kind index (read-word_ words i))
        index++
    else if type == CHUNK-RECORD:
      current-chunk_ = Chunk record[1] record[2] record[3]
      chunks.add current-chunk_
      (process-by-id record[1]).chunks.add current-chunk_
    else if type == DATA-RECORD:
      address := record[1]
      bytes/ByteArray := record[2]
      chunk := current-chunk_
      if not chunk or not chunk.contains address:
        problems.add "data outside of a chunk at 0x$(%x address)"
      else:
        chunk.bytes.replace (address - chunk.address) bytes
    else if type == END-RECORD:
      has-end_ = true
      if record[2] != true: problems.add "the device could not capture everything"
      if record[3] > 0: problems.add "$record[3] processes could not be paused and are missing"
    // Ignore unknown record types, so newer devices can add records.

  decode-malloc-blocks_ bytes/ByteArray -> none:
    position := 0
    read-uleb := :
      result := 0
      shift := 0
      while true:
        byte := bytes[position++]
        result |= (byte & 0x7f) << shift
        shift += 7
        if byte & 0x80 == 0: break
      result
    while position < bytes.size:
      address := read-uleb.call
      size := read-uleb.call
      tag := bytes[position++]
      process := read-uleb.call
      malloc-blocks.add (MallocBlock address size tag (process == 0 ? null : process - 1))

  read-word_ bytes/ByteArray offset/int -> int:
    if word-size == 4: return LITTLE-ENDIAN.uint32 bytes offset
    return LITTLE-ENDIAN.int64 bytes offset

  process-by-id id/int -> ProcessInfo:
    processes.do: | process/ProcessInfo | if process.id == id: return process
    throw "unknown process $id"

  malloc-tag-name tag/int -> string:
    if 0 <= tag < malloc-tag-names.size: return malloc-tag-names[tag]
    return "tag $tag"

  /** Returns the chunk that contains the given address, or null. */
  chunk-containing address/int -> Chunk?:
    low := 0
    high := chunks.size
    while low < high:
      middle := (low + high) / 2
      chunk/Chunk := chunks[middle]
      if address < chunk.address:
        high = middle
      else if address >= chunk.end:
        low = middle + 1
      else:
        return chunk
    return null

  /** Returns the program that contains the given address, or null. */
  program-containing address/int -> ProgramInfo?:
    programs.do --values: | program/ProgramInfo |
      if program.contains address: return program
    return null

  /** Reads a word from a captured chunk. Returns null if the address isn't captured. */
  word-at address/int -> int?:
    chunk := chunk-containing address
    if not chunk or address + word-size > chunk.end: return null
    return read-word_ chunk.bytes (address - chunk.address)
