// Copyright (C) 2018 Toitware ApS.
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

import .snapshot as snapshot
import io show LITTLE-ENDIAN ByteOrder
import uuid show *
import crypto.sha256

abstract class Memory:
  static ENDIAN_ /ByteOrder ::= LITTLE-ENDIAN

  word-size /int
  bytes_    /ByteArray
  from_     /int
  to_       /int

  // Pointer bits for all the memory. This is not just a slice.
  relocation-bits_ /ByteArray

  constructor --.word-size .bytes_ .from_ .to_ .relocation-bits_:

  abstract allocate --bytes/int -> int

  allocate layout/Layout -> int:
    byte-size := layout.byte-size --word-size=word-size
    return allocate --bytes=byte-size

  put-uint8 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 1
    bytes_[at] = value
    return at + 1

  put-uint16 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 2
    ENDIAN_.put-uint16 bytes_ at value
    return at + 2

  put-uint32 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 4
    ENDIAN_.put-uint32 bytes_ at value
    return at + 4

  put-int32 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 4
    ENDIAN_.put-int32 bytes_ at value
    return at + 4

  put-int64 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 8
    ENDIAN_.put-int64 bytes_ at value
    return at + 4

  put-word --at/int offset/int -> int:
    assert: from_ <= at <= to_ - word-size
    ENDIAN_.put-uint bytes_ word-size at offset
    return at + word-size

  put-float64 --at/int value/float -> int:
    assert: from_ <= at <= to_ - 8
    ENDIAN_.put-float64 bytes_ at value
    return at + 8

  put-half-word --at/int offset/int -> int:
    half-word-size := word-size / 2
    assert: from_ <= at <= to_ - half-word-size
    ENDIAN_.put-uint bytes_ half-word-size at offset
    return at + half-word-size

  put-offheap-pointer --force-reloc=false --at/int address/int -> int:
    assert: from_ <= at <= to_ - word-size
    if address != 0 or force-reloc: mark-pointer_ --at=at
    ENDIAN_.put-uint bytes_ word-size at address
    return at + word-size

  put-heap-pointer --at/int heap-address/int -> int:
    assert: from_ <= at <= to_ - word-size
    if ToitHeapObject.is-heap-object heap-address: mark-pointer_ --at=at
    ENDIAN_.put-uint bytes_ word-size at heap-address
    return at + word-size

  put-bytes --at/int value/int --size/int -> int:
    assert: from_ <= at <= to_ - size
    size.repeat: put-uint8 --at=(at + it) value
    return at + size

  put-bytes --at/int values/ByteArray -> int:
    assert: from_ <= at <= to_ - values.size
    bytes_.replace at values
    return at + values.size

  mark-pointer_ --at/int:
    assert: at % word-size == 0
    word-offset := at / word-size
    byte-index := word-offset / 8
    bit-index := word-offset % 8
    relocation-bits_[byte-index] |= 1 << bit-index

class Offheap extends Memory:
  top_ /int := ?

  constructor --word-size/int bytes/ByteArray from/int to/int relocation-bits/ByteArray:
    top_ = from
    super --word-size=word-size bytes from to relocation-bits

  allocate --bytes/int -> int:
    aligned := round-up bytes word-size
    result := top_
    top_ += aligned
    return result

class MemoryBlock:
  from_ /int
  to_   /int
  top_  /int := ?

  /**
  Allocates a new block at the given location $at.
  The size of the block is $page-size.
  The first $reserved bytes are not used for allocations and are skipped.
  */
  constructor --at/int --page-size/int --reserved/int:
    from_ = at
    top_ = at + reserved
    to_ = at + page-size

  /**
  Allocates space for the given object.
  Returns null if no space is left.
  Returns the address (aligned) if the allocation succeeds.
  */
  allocate --bytes/int -> int?:
    result := top_
    new-top := top_ + bytes
    if new-top > to_: return null
    top_ = new-top
    return result

  /** The address of this block. */
  address -> int: return from_

  /** The value of the top pointer. */
  top-address -> int: return top_

class Heap extends Memory:
  top_ /int := ?
  page-size /int
  blocks_ /List := []

  /** Map from snapshot.ToitHeapObjects to their addresses. */
  contained-objects_ /Map := {:}

  constructor --word-size/int --.page-size bytes/ByteArray from/int to/int relocation-bits/ByteArray:
    top_ = from
    super --word-size=word-size bytes from to relocation-bits
    expand

  expand:
    assert: top_ + page-size <= to_
    block-object-size := ToitMemoryBlock.LAYOUT.byte-size --word-size=word-size
    new-block := MemoryBlock --at=top_ --page-size=page-size --reserved=block-object-size
    top_ += page-size
    blocks_.add new-block

  /**
  Stores the given object o in the heap.
  If the object hasn't been seen before, calls $if-absent to compute an address.
  */
  store o/snapshot.ToitHeapObject [--if-absent] -> int:
    // Avoid filling the 'already_written_map' with integers.
    if this is not ToitInteger:
      return contained-objects_.get o --init=if-absent

    // Integers are either going to be encoded as Smis, or as LargeIntegers.
    // The only way they are large integers is, if they are literals, in which
    // case they are already deduplicated (only once in the literal table).
    // As such it's safe to just create call the `write_to_` function as often
    // as we want.
    result := if-absent.call
    // The following 'if' only serves as safeguard against future changes.
    if not ToitInteger.is-smi-address result:
      value := (this as ToitInteger).o_.value
      // A large integer.
      if contained-objects_.contains value:
        throw "Large integers should be deduplicated"
      contained-objects_[value] = result

    return result

  /**
  Allocates space for an object of the given size in $bytes.
  Returns the address (aligned). The returned address is not Smi encoded.
  */
  allocate --bytes/int -> int:
    aligned := round-up bytes word-size
    address := blocks_.last.allocate --bytes=aligned
    if address: return address
    expand
    // Try again.
    return allocate --bytes=bytes

  is-aligned_ bytes/int -> bool:
    return (bytes & (word-size - 1)) == 0

class Image:
  static PAGE-BYTE-SIZE-32 ::= 1 << 12
  static PAGE-BYTE-SIZE-64 ::= 1 << 15

  id      /Uuid
  offheap /Offheap
  heap    /Heap

  word-size /int
  page-size /int

  all-memory /ByteArray
  relocation-bits /ByteArray

  // Hackish way of getting the large_integer header from the
  // program to the ToitInteger class without needing to thread it
  // through every possible function call.
  large-integer-header_ /int? := null

  constructor snapshot-program/snapshot.Program .word-size --.id:
    header := snapshot-program.header
    assert: word-size == 4 or word-size == 8
    page-size = word-size == 4 ? PAGE-BYTE-SIZE-32 : PAGE-BYTE-SIZE-64

    block-count := word-size == 4 ? header.block-count32 : header.block-count64
    block-byte-size := block-count * page-size
    toit-program-byte-size := ToitProgram.LAYOUT.byte-size --word-size=word-size
    summed-offheap := (round-up toit-program-byte-size word-size)
        + (header.offheap-pointer-count * word-size)
        + (round-up (header.offheap-int32-count * 4) word-size)
        + (round-up header.offheap-byte-count word-size)
    offheap-size := round-up summed-offheap page-size
    total-size := offheap-size + block-byte-size
    all-memory = ByteArray total-size
    total-word-count := total-size / word-size
    relocation-bits-byte-count := (total-word-count + 7) / 8
    relocation-bits = ByteArray (round-up relocation-bits-byte-count word-size)
    offheap = Offheap --word-size=word-size all-memory 0 offheap-size relocation-bits
    heap = Heap --word-size=word-size --page-size=page-size all-memory offheap-size total-size relocation-bits

  build-relocatable -> ByteArray:
    final-size := all-memory.size + relocation-bits.size
    result := ByteArray final-size
    out-index := 0
    for i := 0; i < all-memory.size; i++:
      if (i % (word-size * word-size * 8)) == 0:
        index := i / word-size / 8
        relocation-word := LITTLE-ENDIAN.read-uint relocation-bits word-size index
        LITTLE-ENDIAN.put-uint result word-size out-index relocation-word
        out-index += word-size
      result[out-index++] = all-memory[i]
    return result

class LayoutSize:
  words /int
  half-words /int
  bytes /int

  constructor words/int bytes/int --half-words=0:
    this.words = words + half-words / 2
    this.half-words = half-words % 2
    this.bytes = bytes

  constructor.half-word:
    words = 0
    half-words = 1
    bytes = 0

  operator+ other/LayoutSize:
    return LayoutSize
        (words + other.words)
        --half-words=(half-words + other.half-words)
        (bytes + other.bytes)
  operator* count/int:
    return LayoutSize
        (words * count)
        --half-words=(half-words * count)
        (bytes * count)

  in-bytes --word-size/int -> int:
    return words * word-size + half-words * word-size / 2 + bytes

  in-aligned-bytes --word-size/int -> int:
    return round-up (in-bytes --word-size=word-size) word-size

abstract class Layout:
  abstract byte-size --word-size/int -> int

class ObjectType extends Layout:
  fields_ /Map
  packed_ /bool

  constructor --packed/bool=false .fields_:
    packed_ = packed

  operator[] field/string -> Layout:
    return fields_[field]

  anchor --at/int memory/Memory -> AnchoredLayout:
    offset := at
    word-size := memory.word-size
    offsets := {:}
    fields_.do: | field layout/Layout |
      field-byte-size := layout.byte-size --word-size=word-size
      if not packed_:
        align-size := min field-byte-size word-size
        offset = round-up offset align-size
      offsets[field] = offset
      offset += field-byte-size

    return AnchoredLayout memory --offsets=offsets --fields=fields_

  byte-size --word-size/int -> int:
    result := 0
    fields_.do: | field layout/Layout |
      field-byte-size := layout.byte-size --word-size=word-size
      if not packed_:
        align-size := min field-byte-size word-size
        result = round-up result align-size
      result += field-byte-size
    return result

class PrimitiveType extends Layout:
  size /LayoutSize

  constructor .size:

  static UINT8     ::= PrimitiveType (LayoutSize 0 1)
  static UINT16    ::= PrimitiveType (LayoutSize 0 2)
  static UINT32    ::= PrimitiveType (LayoutSize 0 4)
  static INT32     ::= PrimitiveType (LayoutSize 0 4)
  static INT       ::= INT32
  static POINTER   ::= PrimitiveType (LayoutSize 1 0)
  static WORD      ::= PrimitiveType (LayoutSize 1 0)
  static HALF-WORD ::= PrimitiveType LayoutSize.half-word
  static FLOAT64   ::= PrimitiveType (LayoutSize 0 8)
  static INT64     ::= PrimitiveType (LayoutSize 0 8)

  operator* count/int -> PrimitiveType:
    return PrimitiveType (size * count)

  byte-size --word-size/int -> int:
    return size.in-bytes --word-size=word-size

class AnchoredLayout:
  memory_  /Memory
  offsets_ /Map
  fields_  /Map

  constructor .memory_ --offsets --fields:
    offsets_ = offsets
    fields_ = fields

  operator[] field/string -> int:
    return offsets_[field]

  put-uint8 field/string value/int:
    assert: (size-for field) == 1
    offset := offsets_[field]
    memory_.put-uint8 --at=offset value

  put-uint16 field/string value/int:
    assert: (size-for field) == 2
    offset := offsets_[field]
    memory_.put-uint16 --at=offset value

  put-uint32 field/string value/int:
    assert: (size-for field) == 4
    offset := offsets_[field]
    memory_.put-uint32 --at=offset value

  put-int32 field/string value/int:
    assert: (size-for field) == 4
    offset := offsets_[field]
    memory_.put-int32 --at=offset value

  put-float64 field/string value/float:
    assert: (size-for field) == 8
    offset := offsets_[field]
    memory_.put-float64 --at=offset value

  put-int64 field/string value/int:
    assert: (size-for field) == 8
    offset := offsets_[field]
    memory_.put-int64 --at=offset value

  put-word field/string value/int:
    assert: (size-for field) == memory_.word-size
    offset := offsets_[field]
    memory_.put-word --at=offset value

  put-half-word field/string value/int:
    assert: (size-for field) == (memory_.word-size / 2)
    offset := offsets_[field]
    memory_.put-half-word --at=offset value

  put-offheap-pointer field/string address/int:
    assert: (size-for field) == memory_.word-size
    offset := offsets_[field]
    memory_.put-offheap-pointer --at=offset address

  put-heap-pointer field/string address/int:
    assert: (size-for field) == memory_.word-size
    offset := offsets_[field]
    memory_.put-heap-pointer --at=offset address

  put-bytes field/string value/int --size/int:
    assert: (size-for field) == size
    offset := offsets_[field]
    memory_.put-bytes --at=offset value --size=size

  put-bytes field/string values/ByteArray:
    assert: (size-for field) == values.size
    offset := offsets_[field]
    memory_.put-bytes --at=offset values

  size-for field/string -> int:
    layout /Layout := fields_[field]
    assert: layout is PrimitiveType
    return layout.byte-size --word-size=memory_.word-size

  layout-for field/string -> Layout: return fields_[field]

/**
An object that should be serialized into the Heap.

Conventions:
* `write_to image -> address` is used to let the object allocate
  space and write into the image.
* `fill_into image --at=offset -> none` fills an already allocated memory
  area. The fill function may itself allocate new objects.
*/
class ToitObject:

class ToitObjectType extends ToitObject:

class ToitHeader extends ToitObjectType:
  static ID-SIZE ::= Uuid.SIZE
  static METADATA-SIZE ::= 5

  static LAYOUT /ObjectType ::= ObjectType --packed {
    "marker_": PrimitiveType.UINT32,
    "checksum_": PrimitiveType.UINT32,
    "id_": PrimitiveType (LayoutSize 0 ID-SIZE),
    "metadata_": PrimitiveType (LayoutSize 0 METADATA-SIZE),
    "type_": PrimitiveType.UINT8,
    "pages_in_flash_": PrimitiveType.UINT16,
    "uuid_": PrimitiveType (LayoutSize 0 Uuid.SIZE),
  }

  static MARKER_ ::= 0xDEADFACE
  static FLASH-ALLOCATION-TYPE-PROGRAM_ ::= 0

  fill-into image/Image --at/int --system-uuid/Uuid --id/Uuid:
    memory := image.offheap
    anchored := LAYOUT.anchor --at=at memory
    assert: at % memory.word-size == 0
    assert: anchored["uuid_"] % memory.word-size == 0
    assert: id.to-byte-array.size == ID-SIZE
    assert: system-uuid.to-byte-array.size == Uuid.SIZE

    anchored.put-uint32 "marker_" MARKER_
    anchored.put-uint32 "checksum_" 0  // Overwritten on device at install time.
    anchored.put-bytes "id_" id.to-byte-array
    anchored.put-bytes "metadata_" (ByteArray METADATA-SIZE: 0)
    anchored.put-uint8 "type_" FLASH-ALLOCATION-TYPE-PROGRAM_
    anchored.put-uint16 "pages_in_flash_" (image.all-memory.size / 4096)
    anchored.put-bytes "uuid_" system-uuid.to-byte-array

class ToitProgram extends ToitObjectType:
  static CLASS-TAG-BIT-SIZE ::= 4

  /**
  Number of roots.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init-constants below.
  */
  static ROOT-COUNT /int? := null

  /**
  Number of builtin class ids.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init-constants below.
  */
  static BUILT-IN-CLASS-ID-COUNT /int? := null

  /**
  Number of entry points.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init-constants below.
  */
  static ENTRY-POINT-COUNT /int? := null

  /**
  Number of invoke-bytecode offsets.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init-constants below.
  */
  static INVOKE-BYTECODE-COUNT /int? := null

  /**
  Layout of the structure.
  Given a specific VM version this is a constant. However, it is dependent on
    variables that may change for different VM versions. Instead of depending on
    the specific VM version, we require the layout to be initialized before
    used. See $init-constants.
  */
  static LAYOUT /ObjectType? := null

  /**
  Initializes the constants that depend on the VM.
  The Program class contains flat arrays that depend on the number of objects.
  Set the object size here instead of depending on the specific layout.
  */
  static init-constants snapshot-program/snapshot.Program:
    ROOT-COUNT = snapshot-program.roots.size
    BUILT-IN-CLASS-ID-COUNT = snapshot-program.built-in-class-ids.size
    ENTRY-POINT-COUNT = snapshot-program.entry-point-indexes.size
    INVOKE-BYTECODE-COUNT = snapshot-program.invoke-bytecode-offsets.size

    LAYOUT = ObjectType {
      // A field in the superclass of Program.
      "header": ToitHeader.LAYOUT,

      // The fields in the Program class itself.
      "global_variables": ToitTable.LAYOUT,
      "literals": ToitTable.LAYOUT,
      "dispatch_table": ToitList.LAYOUT,
      "class_check_ids": ToitList.LAYOUT,
      "interface_check_offsets": ToitList.LAYOUT,
      "class_bits": ToitList.LAYOUT,
      "bytecodes": ToitList.LAYOUT,
      "snapshot_uuid_": PrimitiveType (LayoutSize 0 Uuid.SIZE),
      "global_max_stack_height": PrimitiveType.WORD,
      "_invoke_bytecode_offsets": PrimitiveType.INT * INVOKE-BYTECODE-COUNT,
      "_heap": ToitRawHeap.LAYOUT,
      "_roots": PrimitiveType.POINTER * ROOT-COUNT,
      "_builtin_class_ids": PrimitiveType.POINTER * BUILT-IN-CLASS-ID-COUNT,
      "_entry_point_indexes": PrimitiveType.INT * ENTRY-POINT-COUNT,
      "_program_heap_address": PrimitiveType.POINTER,
      "_program_heap_size": PrimitiveType.WORD,
    }

  snapshot-program /snapshot.Program
  constructor .snapshot-program:

  write-to image/Image -> int
      --system-uuid/Uuid
      --snapshot-uuid/Uuid:
    word-size := image.word-size
    offheap := image.offheap

    address := offheap.allocate LAYOUT
    anchored := LAYOUT.anchor --at=address offheap

    // The order of writing the fields must be kept in sync with the C++ version.
    // Not only does it allow us to compare the two results more easily, the size
    // of the offheap and heap is computed accordingly. Due to padding we could
    // otherwise need more memory.
    // In theory we could also just stop keeping track of the size inside the snapshot
    // and just dynamically build up the memory here.

    header := ToitHeader  // Doesn't need data from the snapshot.
    header.fill-into image --at=anchored["header"] --system-uuid=system-uuid --id=image.id
    anchored.put-bytes "snapshot_uuid_" snapshot-uuid.to-byte-array

    class-tags := snapshot-program.class-tags
    class-instance-sizes := snapshot-program.class-instance-sizes
    assert: class-tags.size == class-instance-sizes.size
    snapshot-class-bits := List class-tags.size:
      tag := class-tags[it]
      instance-size := class-instance-sizes[it]
      (instance-size << snapshot.Program.CLASS-ID-OFFSET_) | tag

    // Store the large_integer header in the image so we can use it
    // whenever we need to create a large integer.
    large-integer-id := snapshot-program.header.large-integer-id
    large-integer-tag := class-tags[large-integer-id]
    large-integer-header := (large-integer-id << snapshot.Program.CLASS-ID-OFFSET_) | large-integer-tag
    image.large-integer-header_ = ToitInteger.to-smi-address --word-size=word-size large-integer-header

    class-bits := ToitList snapshot-class-bits --element-type=PrimitiveType.UINT16
    class-bits.fill-into image --at=anchored["class_bits"]

    global-variables := ToitTable snapshot-program.global-variables
    global-variables.fill-into image --at=anchored["global_variables"]

    literals := ToitTable snapshot-program.literals
    literals.fill-into image --at=anchored["literals"]

    root-offset := anchored["_roots"]
    ROOT-COUNT.repeat:
      root-object := ToitHeapObject snapshot-program.roots[it]
      root-address := root-object.write-to image
      root-offset = offheap.put-heap-pointer --at=root-offset root-address
    assert: root-offset == (anchored["_roots"] + (LAYOUT["_roots"].byte-size --word-size=word-size))

    builtin-offset := anchored["_builtin_class_ids"]
    BUILT-IN-CLASS-ID-COUNT.repeat:
      builtin-object := ToitHeapObject snapshot-program.built-in-class-ids[it]
      builtin-address := builtin-object.write-to image
      assert: ToitInteger.is-smi-address builtin-address
      builtin-offset = offheap.put-heap-pointer --at=builtin-offset builtin-address
    assert: builtin-offset == (anchored["_builtin_class_ids"] + (LAYOUT["_builtin_class_ids"].byte-size --word-size=word-size))

    invoke-bytecode-offset := anchored["_invoke_bytecode_offsets"]
    INVOKE-BYTECODE-COUNT.repeat:
      element := snapshot-program.invoke-bytecode-offsets[it]
      invoke-bytecode-offset = offheap.put-int32 --at=invoke-bytecode-offset element
    assert: invoke-bytecode-offset == (anchored["_invoke_bytecode_offsets"] + (LAYOUT["_invoke_bytecode_offsets"].byte-size --word-size=word-size))

    entry-offset := anchored["_entry_point_indexes"]
    ENTRY-POINT-COUNT.repeat:
      entry-index := snapshot-program.entry-point-indexes[it]
      entry-offset = offheap.put-int32 --at=entry-offset entry-index

    offheap.put-offheap-pointer --force-reloc --at=anchored["_program_heap_address"] 0
    offheap.put-word --at=anchored["_program_heap_size"] image.all-memory.size

    class-check-ids := ToitList snapshot-program.class-check-ids
        --element-type=PrimitiveType.UINT16
    class-check-ids.fill-into image --at=anchored["class_check_ids"]

    interface-check-offsets := ToitList snapshot-program.interface-check-selectors
        --element-type=PrimitiveType.UINT16
    interface-check-offsets.fill-into image --at=anchored["interface_check_offsets"]

    dispatch-table := ToitList snapshot-program.dispatch-table
        --element-type=PrimitiveType.INT32
    dispatch-table.fill-into image --at=anchored["dispatch_table"]

    bytecodes := ToitUint8List snapshot-program.all-bytecodes
    bytecodes.fill-into image --at=anchored["bytecodes"]

    global-max-index := anchored["global_max_stack_height"]
    offheap.put-word --at=global-max-index snapshot-program.global-max-stack-height

    // Source mapping is kept at null.

    // Now that we have finished writing the whole image, we can update the
    // '_heap' with the correct values.
    toitheap := ToitRawHeap image.heap
    toitheap.fill-into image --at=anchored["_heap"]

    return address

abstract class ToitSequence:
  static LAYOUT /ObjectType ::= ObjectType {
    "_data": PrimitiveType.POINTER,
    "_length": PrimitiveType.INT,
  }

  fill-into image/Image --at/int:
    element-size := element-byte-size --word-size=image.word-size
    needed-bytes := size * element-size
    address := image.offheap.allocate --bytes=needed-bytes
    write-elements image --at=address

    anchored := LAYOUT.anchor --at=at image.offheap
    anchored.put-offheap-pointer "_data" address
    anchored.put-int32 "_length" size

  write-elements image/Image --at/int:
    element-size := element-byte-size --word-size=image.word-size
    size.repeat: write-element it image --at=(at + it * element-size)

  abstract size -> int
  abstract element-byte-size --word-size/int -> int
  abstract write-element index/int image/Image --at/int -> none


class ToitTable extends ToitSequence:
  static LAYOUT /ObjectType ::= ToitSequence.LAYOUT

  list_ /List

  constructor .list_:

  size: return list_.size
  element-byte-size --word-size/int -> int: return word-size
  write-element index/int image/Image --at/int:
    element := list_[index]
    heap-object := ToitHeapObject element
    object-address := heap-object.write-to image
    image.offheap.put-heap-pointer --at=at object-address

class ToitList extends ToitSequence:
  static LAYOUT /ObjectType ::= ToitSequence.LAYOUT

  list_ /List
  element-type_ /PrimitiveType

  constructor .list_ --element-type/PrimitiveType:
    element-type_ = element-type

  size: return list_.size
  element-byte-size --word-size/int -> int: return element-type_.byte-size --word-size=word-size
  write-element index/int image/Image --at/int:
    offheap := image.offheap
    element := list_[index]
    if element-type_ == PrimitiveType.UINT16:
      image.offheap.put-uint16 --at=at element
    else if element-type_ == PrimitiveType.INT32:
      offheap.put-int32 --at=at element
    else:
      throw "UNIMPLEMENTED"

class ToitUint8List extends ToitSequence:
  static LAYOUT /ObjectType ::= ToitSequence.LAYOUT

  bytes_ /ByteArray

  constructor .bytes_:

  size: return bytes_.size
  element-byte-size --word-size/int -> int: return 1
  write-elements image/Image --at/int:
    image.offheap.put-bytes --at=at  bytes_

  write-element index/int image/Image --at/int: unreachable

class ToitRawHeap:
  static LAYOUT /ObjectType ::= ObjectType {
    "_blocks": ToitMemoryBlockList.LAYOUT,
  }

  heap_ /Heap

  constructor .heap_:

  fill-into image/Image --at/int:
    anchored := LAYOUT.anchor image.offheap --at=at
    block-list := ToitMemoryBlockList heap_.blocks_
    block-list.fill-into image --at=anchored["_blocks"]

class ToitMemoryBlockList:
  static LAYOUT /ObjectType ::= ObjectType {
    "_blocks": ToitMemoryBlockLinkedList.LAYOUT,
    "_length": PrimitiveType.WORD,
  }

  blocks_ /List

  constructor .blocks_:

  fill-into image/Image --at/int:
    anchored := LAYOUT.anchor image.offheap --at=at
    linked-list := ToitMemoryBlockLinkedList blocks_
    linked-list.fill-into image --at=anchored["_blocks"]

    anchored.put-word "_length" blocks_.size

class ToitMemoryBlockLinkedList:
  static LAYOUT /ObjectType ::= ObjectType {
    // Inherited from LinkedList<Block>
    // The anchor is a LinkedListElement, which just contains one element '_next'.
    "_anchor": PrimitiveType.POINTER,
    // Inherited from LinkedFifo<Block>
    "_tail": PrimitiveType.POINTER,
  }

  blocks_ /List

  constructor .blocks_:

  fill-into image/Image --at/int:
    anchored := LAYOUT.anchor image.offheap --at=at

    next-address := 0  // Last block has "null" as next.
    for i := blocks_.size - 1; i >= 0; i--:
      block /MemoryBlock := blocks_[i]
      toit-block := ToitMemoryBlock block next-address
      address := block.address
      toit-block.fill-into image --at=address
      next-address = address

      if i == blocks_.size - 1:
        // Last block.
        anchored.put-offheap-pointer "_tail" address
      if i == 0:
        // First block == anchor.
        anchored.put-offheap-pointer "_anchor" address


class ToitMemoryBlock:
  // It's debatable, whether the ToitMemoryblock is an ObjectType. It is clearly
  // located in the heap memory, but it is treated like an offheap-object.
  static LAYOUT /ObjectType ::= ObjectType {
    // Inherited from LinkedListElement.
    "_next": PrimitiveType.POINTER,
    "_top": PrimitiveType.POINTER,
  }

  block_ /MemoryBlock
  next-address_ /int

  constructor .block_ .next-address_:

  fill-into image/Image --at/int:
    // Blocks live in the heap-memory area.
    anchored := LAYOUT.anchor image.heap --at=at
    anchored.put-offheap-pointer "_next" next-address_
    anchored.put-offheap-pointer "_top" block_.top-address


abstract class ToitHeapObject extends ToitObject:
  constructor o/snapshot.ToitHeapObject:
    if o is snapshot.ToitArray:     return ToitArray     (o as snapshot.ToitArray)
    if o is snapshot.ToitByteArray: return ToitByteArray (o as snapshot.ToitByteArray)
    if o is snapshot.ToitString:    return ToitString    (o as snapshot.ToitString)
    if o is snapshot.ToitOddball:   return ToitOddball   (o as snapshot.ToitOddball)
    if o is snapshot.ToitInstance:  return ToitInstance  (o as snapshot.ToitInstance)
    if o is snapshot.ToitFloat:     return ToitFloat     (o as snapshot.ToitFloat)
    if o is snapshot.ToitInteger:   return ToitInteger   (o as snapshot.ToitInteger)
    unreachable

  constructor.from-subclass_:

  static SMI-TAG-SIZE ::= 1
  static SMI-MASK ::= (1 << SMI-TAG-SIZE) - 1

  static NON-SMI-MASK ::= (1 << 2) - 1
  static HEAP-TAG ::= 1

  static MIN-SMI32-VALUE ::= -(1 << 32 - (SMI-TAG-SIZE + 1))
  static MAX-SMI32-VALUE ::= (1 << 32 - (SMI-TAG-SIZE + 1)) - 1

  static MIN-SMI64-VALUE ::= -(1 << 64 - (SMI-TAG-SIZE + 1))
  static MAX-SMI64-VALUE ::= (1 << 64 - (SMI-TAG-SIZE + 1)) - 1

  static is-heap-object address/int -> bool:
    return (address & NON-SMI-MASK) == HEAP-TAG

  /**
  Writes this object to the image unless the object was already written.
  Returns the encoded address of the written object.
  Returns a Smi (see $ToitInteger.is-smi-address) if the object is an integer
    that fits into a Smi.
  */
  write-to image/Image -> int:
    return image.heap.store o_ --if-absent=:
      encoded-address := write-to_ image
      assert: this is ToitInteger or not ToitInteger.is-smi-address encoded-address
      encoded-address

  abstract o_ -> snapshot.ToitHeapObject

  /**
  Writes this object to the image.
  Returns the encoded address (distinguishing between Smis and pointers).
  */
  abstract write-to_ image/Image -> int

  write-header-to_ image/Image --at/int:
    header-value := ToitInteger.to-smi-address o_.header --word-size=image.word-size
    image.heap.put-word --at=at header-value

  /**
  Smi-encodes the given address.
  */
  to-encoded-address address/int -> int:
    assert: (address & NON-SMI-MASK) == 0
    return address + HEAP-TAG

class ToitArray extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // A length followed by the objects.
    "length": PrimitiveType.WORD,
  }

  o_/snapshot.ToitArray
  constructor .o_: super.from-subclass_

  write-to_ image/Image -> int:
    word-size := image.word-size
    size := o_.content.size
    array-header-byte-size := LAYOUT.byte-size --word-size=word-size
    needed-bytes := array-header-byte-size + (size * word-size)
    address := image.heap.allocate --bytes=needed-bytes
    anchored := LAYOUT.anchor image.heap --at=address

    write-header-to_ image --at=anchored["header"]
    anchored.put-word "length" size

    size.repeat:
      element := o_.content[it]
      element-address := (ToitHeapObject element).write-to image
      element-offset := address + array-header-byte-size + it * word-size
      image.heap.put-heap-pointer --at=element-offset element-address

    return to-encoded-address address

class ToitByteArray extends ToitHeapObject:
  static INTERNAL-SIZE-CUTOFF := Image.PAGE-BYTE-SIZE-32 >> 2
  static RAW-BYTE-TAG ::= 0

  static LAYOUT-INTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // A length followed by the bytes.
    "length": PrimitiveType.WORD,
  }

  static LAYOUT-EXTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // A length set to -1-real_length, followed by the external address and a tag.
    "length": PrimitiveType.WORD,
    "external_address": PrimitiveType.POINTER,
    "tag": PrimitiveType.WORD,
  }

  o_/snapshot.ToitByteArray
  constructor .o_: super.from-subclass_

  write-to_ image/Image -> int:
    if o_.content.size > INTERNAL-SIZE-CUTOFF:
      return write-external-to_ image
    return write-internal-to_ image

  write-internal-to_ image/Image -> int:
    word-size := image.word-size
    size := o_.content.size
    byte-array-header-size := LAYOUT-INTERNAL.byte-size --word-size=word-size
    needed-bytes := byte-array-header-size + size
    address := image.heap.allocate --bytes=needed-bytes
    anchored := LAYOUT-INTERNAL.anchor image.heap --at=address

    write-header-to_ image --at=anchored["header"]
    anchored.put-word "length" size
    image.heap.put-bytes --at=(address + byte-array-header-size) o_.content

    return to-encoded-address address

  write-external-to_ image/Image -> int:
    size := o_.content.size
    word-size := image.word-size
    address := image.heap.allocate LAYOUT-EXTERNAL
    anchored := LAYOUT-EXTERNAL.anchor image.heap --at=address

    write-header-to_ image --at=anchored["header"]
    // Encode the size so it is recognized as external byte array.
    anchored.put-word "length" (-1 - size)

    external-address := image.offheap.allocate --bytes=size
    image.offheap.put-bytes --at=external-address o_.content

    anchored.put-offheap-pointer "external_address" external-address

    // A snapshot can only contain raw bytes at the moment.
    anchored.put-word "tag" RAW-BYTE-TAG

    return to-encoded-address address

class ToitString extends ToitHeapObject:
  static INTERNAL-SIZE-CUTOFF ::= Image.PAGE-BYTE-SIZE-32 >> 2
  static EXTERNAL-LENGTH-SENTINEL ::= 65535  // On 64-bit machines, this is not -1 when stored in a half-word.

  static LAYOUT-INTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // Internal representation of a string contains a few bits for the
    // hashcode and then the length.
    // The content is following the length.
    "hash_code": PrimitiveType.HALF-WORD,
    "length": PrimitiveType.HALF-WORD,
  }

  static LAYOUT-EXTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // External representation of a string contains a few bits for the
    // hashcode and then the length which is set to EXTERNAL_LENGTH_SENTINEL.
    // It is then followed by the real length and a pointer to the external address.
    "hash_code": PrimitiveType.HALF-WORD,
    "length": PrimitiveType.HALF-WORD,
    "real_length": PrimitiveType.WORD,
    "external_address": PrimitiveType.POINTER,
  }

  o_/snapshot.ToitString
  constructor .o_: super.from-subclass_

  write-to_ image/Image -> int:
    if o_.content.size > INTERNAL-SIZE-CUTOFF:
      return write-external-to_ image
    return write-internal-to_ image

  write-internal-to_ image/Image -> int:
    size := o_.content.size
    null-terminated-size := size + 1
    string-header-byte-size := LAYOUT-INTERNAL.byte-size --word-size=image.word-size
    needed-bytes := string-header-byte-size + null-terminated-size
    address := image.heap.allocate --bytes=needed-bytes
    anchored := LAYOUT-INTERNAL.anchor image.heap --at=address

    write-header-to_ image --at=anchored["header"]

    hash := compute-hash_
    anchored.put-half-word "hash_code" hash
    anchored.put-half-word "length" size
    image.heap.put-bytes --at=(address + string-header-byte-size) o_.content
    // Null terminate the string.
    image.heap.put-uint8 --at=(address + string-header-byte-size + size) 0

    return to-encoded-address address

  write-external-to_ image/Image -> int:
    size := o_.content.size
    null-terminated-size := size + 1
    address := image.heap.allocate LAYOUT-EXTERNAL
    anchored := LAYOUT-EXTERNAL.anchor image.heap --at=address

    write-header-to_ image --at=anchored["header"]

    hash := compute-hash_
    anchored.put-half-word "hash_code" hash

    // External representation has a sentinel as length.
    anchored.put-half-word "length" EXTERNAL-LENGTH-SENTINEL

    anchored.put-word "real_length" size

    content-address := image.offheap.allocate --bytes=null-terminated-size
    image.offheap.put-bytes --at=content-address o_.content
    // Null terminate.
    image.offheap.put-uint8 --at=(content-address + size) 0

    anchored.put-offheap-pointer "external_address" content-address

    return to-encoded-address address

  // This constant must be kept in sync with objects.cc.
  static NO-HASH-CODE_ ::= 0xFFFF

  compute-hash_ -> int:
    // Keep an assert to detect when we do changes to the way we compute the hash.
    assert: "hello world".hash-code == 64985
    hash := (o_.content.size) & 0xFFFF
    o_.content.do:
      hash = (31 * hash + it) & 0xFFFF
    if hash == NO-HASH-CODE_: hash = 0
    return hash

class ToitOddball extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType {
    "header": PrimitiveType.WORD,
  }

  o_/snapshot.ToitOddball
  constructor .o_: super.from-subclass_

  write-to_ image/Image -> int:
    address := image.heap.allocate LAYOUT
    anchored := LAYOUT.anchor image.heap --at=address
    write-header-to_ image --at=anchored["header"]
    return to-encoded-address address

class ToitInstance extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType {
    // A header followed by the fields.
    "header": PrimitiveType.WORD,
  }

  o_/snapshot.ToitInstance
  constructor .o_: super.from-subclass_

  write-to_ image/Image -> int:
    word-size := image.word-size
    header-byte-size := LAYOUT.byte-size --word-size=word-size
    needed-bytes := header-byte-size + o_.fields.size * word-size
    address := image.heap.allocate --bytes=needed-bytes
    anchored := LAYOUT.anchor image.heap --at=address
    write-header-to_ image --at=anchored["header"]

    o_.fields.size.repeat:
      field := o_.fields[it]
      field-address := (ToitHeapObject field).write-to image
      field-offset := address + header-byte-size + (it * word-size)
      image.heap.put-heap-pointer --at=field-offset field-address

    return to-encoded-address address

class ToitFloat extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType {
    // A header followed by the 8 byte float value.
    "header": PrimitiveType.WORD,
    "value": PrimitiveType.FLOAT64,
  }

  o_/snapshot.ToitFloat
  constructor .o_: super.from-subclass_

  write-to_ image/Image -> int:
    address := image.heap.allocate LAYOUT
    anchored := LAYOUT.anchor image.heap --at=address
    write-header-to_ image --at=anchored["header"]
    anchored.put-float64 "value" o_.value
    return to-encoded-address address

class ToitInteger extends ToitHeapObject:
  static LAYOUT-LARGE-INTEGER /ObjectType ::= ObjectType {
    // A header followed by the 8 byte integer value.
    "header": PrimitiveType.WORD,
    "value": PrimitiveType.INT64,
  }

  static is-smi-address address/int -> bool:
    return (address & ToitHeapObject.SMI-MASK) == 0

  static is-valid-smi x/int --word-size/int:
    if word-size == 4:
      return ToitHeapObject.MIN-SMI32-VALUE <= x <= ToitHeapObject.MAX-SMI32-VALUE
    return ToitHeapObject.MIN-SMI64-VALUE <= x <= ToitHeapObject.MAX-SMI64-VALUE

  static to-smi-address x/int --word-size/int -> int:
    assert: is-valid-smi x --word-size=word-size
    return x << ToitHeapObject.SMI-TAG-SIZE

  o_/snapshot.ToitInteger
  constructor .o_: super.from-subclass_

  is-valid-smi --word-size/int:
    return is-valid-smi o_.value --word-size=word-size

  to-smi-address --word-size/int -> int:
    return to-smi-address o_.value --word-size=word-size

  write-to_ image/Image -> int:
    word-size := image.word-size
    // ToitIntegers are the only objects that don't have a header.
    assert: o_.header == null
    if is-valid-smi --word-size=word-size:
      return to-smi-address --word-size=word-size

    address := image.heap.allocate LAYOUT-LARGE-INTEGER
    anchored := LAYOUT-LARGE-INTEGER.anchor image.heap --at=address

    header := image.large-integer-header_
    assert: header != null // Must have been set when writing the Program.
    anchored.put-word "header" header
    anchored.put-int64 "value" o_.value
    return to-encoded-address address

build-image snapshot/snapshot.Program word-size/int -> Image
    --system-uuid/Uuid
    --snapshot-uuid/Uuid
    --assets/ByteArray?:
  id := image-id --snapshot-uuid=snapshot-uuid --assets=assets
  return build-image snapshot word-size
      --system-uuid=system-uuid
      --snapshot-uuid=snapshot-uuid
      --id=id

build-image snapshot/snapshot.Program word-size/int -> Image
    --system-uuid/Uuid
    --snapshot-uuid/Uuid
    --id/Uuid:
  ToitProgram.init-constants snapshot
  image := Image snapshot word-size --id=id
  program := ToitProgram snapshot
  program.write-to image
      --system-uuid=system-uuid
      --snapshot-uuid=snapshot-uuid
  return image

image-id --snapshot-uuid/Uuid --assets/ByteArray? -> Uuid:
  // Compute a stable id for the program based on the snapshot
  // and the assets. This way, the word size doesn't impact the
  // generated id.
  sha := sha256.Sha256
  sha.add snapshot-uuid.to-byte-array
  if assets: sha.add assets
  return Uuid sha.get[..Uuid.SIZE]
