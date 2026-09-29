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
Decodes the Toit objects in the captured heap of a process.

The object layout comes from the capture's layout record, and the instance
  sizes come from the class bits of the process' program. The decoding
  mirrors `HeapObject::size` and `HeapObject::roots_do` in src/objects.cc.
*/

import io show LITTLE-ENDIAN

import .capture

/** An object in a captured heap. */
class HeapObject:
  address/int
  class-id/int
  class-tag/int
  size/int := 0
  /** The address of external content (for external strings and byte arrays), or null. */
  external-address/int? := null
  /** The size of external content if known from the object, or null. */
  external-size/int? := null
  /** The struct tag of an external byte array, or null. */
  struct-tag/int? := null

  constructor .address .class-id .class-tag:

class Heap:
  capture/Capture
  process/ProcessInfo
  program/ProgramInfo

  // Layout constants.
  word-size_/int
  non-smi-tag-mask_/int
  heap-tag_/int
  smi-tag-size_/int
  class-tag-offset_/int
  class-tag-mask_/int
  class-id-offset_/int

  /** All objects of the heap, in address order. */
  objects/List ::= []
  objects-by-address_/Map ::= {:}
  /** Problems found while decoding. */
  problems/List ::= []

  constructor .capture .process:
    program = capture.programs[process.program-address]
    layout := capture.layout
    word-size_ = capture.word-size
    non-smi-tag-mask_ = layout["non-smi-tag-mask"]
    heap-tag_ = layout["heap-tag"]
    smi-tag-size_ = layout["smi-tag-size"]
    class-tag-offset_ = layout["class-tag-offset"]
    class-tag-mask_ = (1 << layout["class-tag-bit-size"]) - 1
    class-id-offset_ = layout["class-id-offset"]
    process.chunks.do: | chunk/Chunk | decode-chunk_ chunk

  layout_ name/string -> int: return capture.layout[name]

  tag_ name/string -> int: return capture.layout["$(name)-tag"]

  align_ size/int -> int: return (size + word-size_ - 1) & -word-size_

  /** Returns the object at the given (untagged) address, or null. */
  object-at address/int -> HeapObject?:
    return objects-by-address_.get address

  is-heap-pointer value/int -> bool:
    return value & non-smi-tag-mask_ == heap-tag_

  is-smi value/int -> bool:
    return value & ((1 << smi-tag-size_) - 1) == 0

  /** Returns the object that the tagged $value points to, if it is in this heap. */
  object-for-value value/int -> HeapObject?:
    if not is-heap-pointer value: return null
    return object-at value - heap-tag_

  /** Interprets a word as a signed value. */
  signed value/int -> int:
    if word-size_ == 4 and value >= 0x8000_0000: return value - 0x1_0000_0000
    return value

  word-at_ chunk/Chunk address/int -> int:
    offset := address - chunk.address
    if word-size_ == 4: return LITTLE-ENDIAN.uint32 chunk.bytes offset
    return LITTLE-ENDIAN.int64 chunk.bytes offset

  decode-chunk_ chunk/Chunk -> none:
    current := chunk.address
    // The chunk ends with a zero sentinel word.
    while current + word-size_ <= chunk.end:
      header := word-at_ chunk current
      if header == 0: return
      if not is-smi header:
        problems.add "invalid header at 0x$(%x current)"
        return
      value := (signed header) >> smi-tag-size_
      class-id := value >> class-id-offset_
      class-tag := (value >> class-tag-offset_) & class-tag-mask_
      object := HeapObject current class-id class-tag
      size := size-of_ chunk object
      if size <= 0 or current + size > chunk.end:
        problems.add "invalid object size $size at 0x$(%x current)"
        return
      object.size = size
      if not is-free_ object:
        objects.add object
        objects-by-address_[current] = object
      current += size

  is-free_ object/HeapObject -> bool:
    tag := object.class-tag
    return tag == (tag_ "free-list-region")
        or tag == (tag_ "single-free-word")
        or tag == (tag_ "promoted-track")

  size-of_ chunk/Chunk object/HeapObject -> int:
    address := object.address
    if object.class-id >= 0:
      if object.class-id >= program.class-bits.size: return -1
      bits := program.class-bits[object.class-id]
      instance-size := (bits >> (layout_ "class-bits-instance-size-offset")) & (layout_ "class-bits-instance-size-mask")
      if instance-size != 0: return instance-size * word-size_
    tag := object.class-tag
    if tag == (tag_ "array"):
      length := word-at_ chunk address + (layout_ "array-length-offset")
      return align_ (layout_ "array-header-size") + length * word-size_
    if tag == (tag_ "byte-array"):
      raw-length := signed (word-at_ chunk address + (layout_ "byte-array-length-offset"))
      if raw-length >= 0: return align_ (layout_ "byte-array-header-size") + raw-length
      object.external-address = word-at_ chunk address + (layout_ "byte-array-external-address-offset")
      object.struct-tag = word-at_ chunk address + (layout_ "byte-array-external-tag-offset")
      if object.struct-tag == (layout_ "raw-byte-tag"): object.external-size = -1 - raw-length
      return layout_ "byte-array-external-size"
    if tag == (tag_ "string"):
      offset := address + (layout_ "string-internal-length-offset") - chunk.address
      length := word-size_ == 4
          ? LITTLE-ENDIAN.uint16 chunk.bytes offset
          : LITTLE-ENDIAN.uint32 chunk.bytes offset
      if length != (layout_ "string-sentinel"):
        return align_ (layout_ "string-overhead") + length
      external-length := word-at_ chunk address + (layout_ "string-external-length-offset")
      object.external-address = word-at_ chunk address + (layout_ "string-external-address-offset")
      object.external-size = external-length + 1
      return align_ (layout_ "string-external-object-size")
    if tag == (tag_ "stack"):
      length := word-at_ chunk address + (layout_ "stack-length-offset")
      return align_ (layout_ "stack-header-size") + length * word-size_
    if tag == (tag_ "double"): return layout_ "double-size"
    if tag == (tag_ "large-integer"): return layout_ "large-integer-size"
    if tag == (tag_ "free-list-region"):
      return word-at_ chunk address + (layout_ "free-list-region-size-offset")
    if tag == (tag_ "promoted-track"):
      return (word-at_ chunk address + (layout_ "promoted-track-end-offset")) - address
    if tag == (tag_ "single-free-word"): return word-size_
    return -1

  /**
  Calls $block with the index and value of every word of the object that can
    hold a reference to another object.
  */
  pointer-fields object/HeapObject [block] -> none:
    tag := object.class-tag
    chunk := capture.chunk-containing object.address
    if tag == (tag_ "array"):
      header := layout_ "array-header-size"
      length := word-at_ chunk object.address + (layout_ "array-length-offset")
      length.repeat: | i |
        block.call i (word-at_ chunk object.address + header + i * word-size_)
    else if tag == (tag_ "instance") or tag == (tag_ "task"):
      header := layout_ "instance-header-size"
      fields := (object.size - header) / word-size_
      fields.repeat: | i |
        block.call i (word-at_ chunk object.address + header + i * word-size_)
    else if tag == (tag_ "stack"):
      header := layout_ "stack-header-size"
      length := word-at_ chunk object.address + (layout_ "stack-length-offset")
      top := word-at_ chunk object.address + (layout_ "stack-top-offset")
      bytecodes-start := program.bytecodes-address
      bytecodes-end := bytecodes-start + program.bytecodes-size
      for i := top; i < length; i++:
        value := word-at_ chunk object.address + header + i * word-size_
        // Return addresses and frame markers point into the bytecodes.
        if bytecodes-start <= value <= bytecodes-end: continue
        block.call i value

  /** Returns the objects in this heap that $object references. */
  references object/HeapObject -> List:
    result := []
    pointer-fields object: | _ value |
      referenced := object-for-value value
      if referenced: result.add referenced
    return result

  /** Reads the given number of bytes of an object. */
  bytes-of object/HeapObject offset/int size/int -> ByteArray:
    chunk := capture.chunk-containing object.address
    start := object.address + offset - chunk.address
    return chunk.bytes[start..start + size]

  /** Returns the content of an internal string or byte array, or null. */
  content object/HeapObject -> ByteArray?:
    if object.external-address: return null
    tag := object.class-tag
    chunk := capture.chunk-containing object.address
    if tag == (tag_ "string"):
      offset := object.address + (layout_ "string-internal-length-offset") - chunk.address
      length := word-size_ == 4
          ? LITTLE-ENDIAN.uint16 chunk.bytes offset
          : LITTLE-ENDIAN.uint32 chunk.bytes offset
      return bytes-of object (layout_ "string-internal-header-size") length
    if tag == (tag_ "byte-array"):
      length := word-at_ chunk object.address + (layout_ "byte-array-length-offset")
      return bytes-of object (layout_ "byte-array-header-size") length
    return null
