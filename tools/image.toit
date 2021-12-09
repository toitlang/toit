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
import bytes
import binary show LITTLE_ENDIAN ByteOrder

abstract class Memory:
  static ENDIAN_ /ByteOrder ::= LITTLE_ENDIAN

  word_size /int
  bytes_    /ByteArray
  from_     /int
  to_       /int

  // Pointer bits for all the memory. This is not just a slice.
  relocation_bits_ /ByteArray

  constructor --.word_size .bytes_ .from_ .to_ .relocation_bits_:

  abstract allocate --bytes/int -> int

  allocate layout/Layout -> int:
    byte_size := layout.byte_size --word_size=word_size
    return allocate --bytes=byte_size

  put_uint8 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 1
    bytes_[at] = value
    return at + 1

  put_uint16 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 2
    ENDIAN_.put_uint16 bytes_ at value
    return at + 2

  put_uint32 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 4
    ENDIAN_.put_uint32 bytes_ at value
    return at + 4

  put_int32 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 4
    ENDIAN_.put_int32 bytes_ at value
    return at + 4

  put_int64 --at/int value/int -> int:
    assert: from_ <= at <= to_ - 8
    ENDIAN_.put_int64 bytes_ at value
    return at + 4

  put_word --at/int offset/int -> int:
    assert: from_ <= at <= to_ - word_size
    ENDIAN_.put_uint bytes_ word_size at offset
    return at + word_size

  put_float64 --at/int value/float -> int:
    assert: from_ <= at <= to_ - 8
    ENDIAN_.put_float64 bytes_ at value
    return at + 8

  put_half_word --at/int offset/int -> int:
    half_word_size := word_size / 2
    assert: from_ <= at <= to_ - half_word_size
    ENDIAN_.put_uint bytes_ half_word_size at offset
    return at + half_word_size

  put_offheap_pointer --at/int address/int -> int:
    assert: from_ <= at <= to_ - word_size
    if address != 0: mark_pointer_ --at=at
    ENDIAN_.put_uint bytes_ word_size at address
    return at + word_size

  put_heap_pointer --at/int heap_address/int -> int:
    assert: from_ <= at <= to_ - word_size
    if ToitHeapObject.is_heap_object heap_address: mark_pointer_ --at=at
    ENDIAN_.put_uint bytes_ word_size at heap_address
    return at + word_size

  put_bytes --at/int value/int --size/int -> int:
    assert: from_ <= at <= to_ - size
    size.repeat: put_uint8 --at=(at + it) value
    return at + size

  put_bytes --at/int values/ByteArray -> int:
    assert: from_ <= at <= to_ - values.size
    bytes_.replace at values
    return at + values.size

  mark_pointer_ --at/int:
    assert: at % word_size == 0
    word_offset := at / word_size
    byte_index := word_offset / 8
    bit_index := word_offset % 8
    relocation_bits_[byte_index] |= 1 << bit_index

class Offheap extends Memory:
  top_ /int := ?

  constructor --word_size/int bytes/ByteArray from/int to/int relocation_bits/ByteArray:
    top_ = from
    super --word_size=word_size bytes from to relocation_bits

  allocate --bytes/int -> int:
    aligned := round_up bytes word_size
    result := top_
    top_ += aligned
    return result

class MemoryBlock:
  from_ /int
  to_   /int
  top_  /int := ?

  /**
  Allocates a new block at the given location $at.
  The size of the block is $page_size.
  The first $reserved bytes are not used for allocations and are skipped.
  */
  constructor --at/int --page_size/int --reserved/int:
    from_ = at
    top_ = at + reserved
    to_ = at + page_size

  /**
  Allocates space for the given object.
  Returns null if no space is left.
  Returns the address (aligned) if the allocation succeeds.
  */
  allocate --bytes/int -> int?:
    result := top_
    new_top := top_ + bytes
    if new_top > to_: return null
    top_ = new_top
    return result

  /** The address of this block. */
  address -> int: return from_

  /** The value of the top pointer. */
  top_address -> int: return top_

class Heap extends Memory:
  top_ /int := ?
  page_size /int
  blocks_ /List := []

  /** Map from snapshot.ToitHeapObjects to their addresses. */
  contained_objects_ /Map := {:}

  constructor --word_size/int --.page_size bytes/ByteArray from/int to/int relocation_bits/ByteArray:
    top_ = from
    super --word_size=word_size bytes from to relocation_bits
    expand

  expand:
    assert: top_ + page_size <= to_
    block_object_size := ToitMemoryBlock.LAYOUT.byte_size --word_size=word_size
    new_block := MemoryBlock --at=top_ --page_size=page_size --reserved=block_object_size
    top_ += page_size
    blocks_.add new_block

  /**
  Stores the given object o in the heap.
  If the object hasn't been seen before, calls $if_absent to compute an address.
  */
  store o/snapshot.ToitHeapObject [--if_absent] -> int:
    // Avoid filling the 'already_written_map' with integers.
    if this is not ToitInteger:
      return contained_objects_.get o --init=if_absent

    // Integers are either going to be encoded as Smis, or as LargeIntegers.
    // The only way they are large integers is, if they are literals, in which
    // case they are already deduplicated (only once in the literal table).
    // As such it's safe to just create call the `write_to_` function as often
    // as we want.
    result := if_absent.call
    // The following 'if' only serves as safeguard against future changes.
    if not ToitInteger.is_smi_address result:
      value := (this as ToitInteger).o_.value
      // A large integer.
      if contained_objects_.contains value:
        throw "Large integers should be deduplicated"
      contained_objects_[value] = result

    return result

  /**
  Allocates space for an object of the given size in $bytes.
  Returns the address (aligned). The returned address is not Smi encoded.
  */
  allocate --bytes/int -> int:
    aligned := round_up bytes word_size
    address := blocks_.last.allocate --bytes=aligned
    if address: return address
    expand
    // Try again.
    return allocate --bytes=bytes

  is_aligned_ bytes/int -> bool:
    return (bytes & (word_size - 1)) == 0

class Image:
  static PAGE_BYTE_SIZE_32 ::= 1 << 12
  static PAGE_BYTE_SIZE_64 ::= 1 << 15

  offheap /Offheap
  heap    /Heap

  word_size /int
  page_size /int

  all_memory /ByteArray
  relocation_bits /ByteArray

  // Hackish way of getting the large_integer header from the
  // program to the ToitInteger class without needing to thread it
  // through every possible function call.
  large_integer_header_ /int? := null

  constructor snapshot_program/snapshot.Program .word_size:
    header := snapshot_program.header
    assert: word_size == 4 or word_size == 8
    page_size = word_size == 4 ? PAGE_BYTE_SIZE_32 : PAGE_BYTE_SIZE_64

    block_count := word_size == 4 ? header.block_count32 : header.block_count64
    block_byte_size := block_count * page_size
    toit_program_byte_size := ToitProgram.LAYOUT.byte_size --word_size=word_size
    summed_offheap := (round_up toit_program_byte_size word_size)
        + (header.offheap_pointer_count * word_size)
        + (round_up (header.offheap_int32_count * 4) word_size)
        + (round_up header.offheap_byte_count word_size)
    offheap_size := round_up summed_offheap page_size
    total_size := offheap_size + block_byte_size
    all_memory = ByteArray total_size
    total_word_count := total_size / word_size
    relocation_bits_byte_count := (total_word_count + 7) / 8
    relocation_bits = ByteArray (round_up relocation_bits_byte_count word_size)
    offheap = Offheap --word_size=word_size all_memory 0 offheap_size relocation_bits
    heap = Heap --word_size=word_size --page_size=page_size all_memory offheap_size total_size relocation_bits

  build_relocatable -> ByteArray:
    final_size := all_memory.size + relocation_bits.size
    result := ByteArray final_size
    out_index := 0
    for i := 0; i < all_memory.size; i++:
      if (i % (word_size * word_size * 8)) == 0:
        index := i / word_size / 8
        relocation_word := LITTLE_ENDIAN.read_uint relocation_bits word_size index
        LITTLE_ENDIAN.put_uint result word_size out_index relocation_word
        out_index += word_size
      result[out_index++] = all_memory[i]
    return result

class LayoutSize:
  words /int
  half_words /int
  bytes /int

  constructor words/int bytes/int --half_words=0:
    this.words = words + half_words / 2
    this.half_words = half_words % 2
    this.bytes = bytes

  constructor.half_word:
    words = 0
    half_words = 1
    bytes = 0

  operator+ other/LayoutSize:
    return LayoutSize
        (words + other.words)
        --half_words=(half_words + other.half_words)
        (bytes + other.bytes)
  operator* count/int:
    return LayoutSize
        (words * count)
        --half_words=(half_words * count)
        (bytes * count)

  in_bytes --word_size/int -> int:
    return words * word_size + half_words * word_size / 2 + bytes

  in_aligned_bytes --word_size/int -> int:
    return round_up (in_bytes --word_size=word_size) word_size

abstract class Layout:
  abstract byte_size --word_size/int -> int

class ObjectType extends Layout:
  fields_ /Map
  packed_ /bool

  constructor --packed/bool=false .fields_:
    packed_ = packed

  operator[] field/string -> Layout:
    return fields_[field]

  anchor --at/int memory/Memory -> AnchoredLayout:
    offset := at
    word_size := memory.word_size
    offsets := {:}
    fields_.do: | field layout/Layout |
      field_byte_size := layout.byte_size --word_size=word_size
      if not packed_:
        align_size := min field_byte_size word_size
        offset = round_up offset align_size
      offsets[field] = offset
      offset += field_byte_size

    return AnchoredLayout memory --offsets=offsets --fields=fields_

  byte_size --word_size/int -> int:
    result := 0
    fields_.do: | field layout/Layout |
      field_byte_size := layout.byte_size --word_size=word_size
      if not packed_:
        align_size := min field_byte_size word_size
        result = round_up result align_size
      result += field_byte_size
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
  static HALF_WORD ::= PrimitiveType LayoutSize.half_word
  static FLOAT64   ::= PrimitiveType (LayoutSize 0 8)
  static INT64     ::= PrimitiveType (LayoutSize 0 8)

  operator* count/int -> PrimitiveType:
    return PrimitiveType (size * count)

  byte_size --word_size/int -> int:
    return size.in_bytes --word_size=word_size

class AnchoredLayout:
  memory_  /Memory
  offsets_ /Map
  fields_  /Map

  constructor .memory_ --offsets --fields:
    offsets_ = offsets
    fields_ = fields

  operator[] field/string -> int:
    return offsets_[field]

  put_uint8 field/string value/int:
    assert: (size_for field) == 1
    offset := offsets_[field]
    memory_.put_uint8 --at=offset value

  put_uint16 field/string value/int:
    assert: (size_for field) == 2
    offset := offsets_[field]
    memory_.put_uint16 --at=offset value

  put_uint32 field/string value/int:
    assert: (size_for field) == 4
    offset := offsets_[field]
    memory_.put_uint32 --at=offset value

  put_int32 field/string value/int:
    assert: (size_for field) == 4
    offset := offsets_[field]
    memory_.put_int32 --at=offset value

  put_float64 field/string value/float:
    assert: (size_for field) == 8
    offset := offsets_[field]
    memory_.put_float64 --at=offset value

  put_int64 field/string value/int:
    assert: (size_for field) == 8
    offset := offsets_[field]
    memory_.put_int64 --at=offset value

  put_word field/string value/int:
    assert: (size_for field) == memory_.word_size
    offset := offsets_[field]
    memory_.put_word --at=offset value

  put_half_word field/string value/int:
    assert: (size_for field) == (memory_.word_size / 2)
    offset := offsets_[field]
    memory_.put_half_word --at=offset value

  put_offheap_pointer field/string address/int:
    assert: (size_for field) == memory_.word_size
    offset := offsets_[field]
    memory_.put_offheap_pointer --at=offset address

  put_heap_pointer field/string address/int:
    assert: (size_for field) == memory_.word_size
    offset := offsets_[field]
    memory_.put_heap_pointer --at=offset address

  put_bytes field/string value/int --size/int:
    assert: (size_for field) == size
    offset := offsets_[field]
    memory_.put_bytes --at=offset value --size=size

  put_bytes field/string values/ByteArray:
    assert: (size_for field) == values.size
    offset := offsets_[field]
    memory_.put_bytes --at=offset values

  size_for field/string -> int:
    layout /Layout := fields_[field]
    assert: layout is PrimitiveType
    return layout.byte_size --word_size=memory_.word_size

  layout_for field/string -> Layout: return fields_[field]

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
  static ID_SIZE ::= 16
  static META_DATA_SIZE ::= 5
  static UUID_SIZE ::= 16

  static LAYOUT /ObjectType ::= ObjectType --packed {
    "_marker": PrimitiveType.UINT32,
    "_me": PrimitiveType.UINT32,
    "_id": PrimitiveType (LayoutSize 0 ID_SIZE),
    "_meta_data": PrimitiveType (LayoutSize 0 META_DATA_SIZE),
    "_pages_in_flash": PrimitiveType.UINT16,
    "_type": PrimitiveType.UINT8,
    "_uuid": PrimitiveType (LayoutSize 0 UUID_SIZE),
  }

  static MARKER_ ::= 0xDEADFACE

  fill_into image/Image --at/int:
    memory := image.offheap
    anchored := LAYOUT.anchor --at=at memory
    assert: at % memory.word_size == 0
    assert: anchored["_uuid"] % memory.word_size == 0

    anchored.put_uint32 "_marker" MARKER_
    anchored.put_uint32 "_me" at
    anchored.put_bytes "_id" 0 --size=ID_SIZE
    anchored.put_bytes "_meta_data" 0xFF --size=META_DATA_SIZE
    anchored.put_uint16 "_pages_in_flash" 0
    anchored.put_uint8 "_type" 0 // TODO(florian): we don't seem to initialize the type field in the C++ code.
    anchored.put_bytes "_uuid" 0 --size=UUID_SIZE

class ToitProgram extends ToitObjectType:
  static CLASS_TAG_BIT_SIZE ::= 4

  /**
  Number of roots.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init_constants below.
  */
  static ROOT_COUNT /int? := null

  /**
  Number of builtin class ids.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init_constants below.
  */
  static BUILT_IN_CLASS_ID_COUNT /int? := null

  /**
  Number of entry points.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init_constants below.
  */
  static ENTRY_POINT_COUNT /int? := null

  /**
  Number of invoke-bytecode offsets.
  Given a specific VM version this is a constant.
  Since we want to make it easier to change the VM, we don't hardcode a value here,
    but read it from the snapshot. This is done in the $init_constants below.
  */
  static INVOKE_BYTECODE_COUNT /int? := null

  /**
  Layout of the structure.
  Given a specific VM version this is a constant. However, it is dependent on
    variables that may change for different VM versions. Instead of depending on
    the specific VM version, we require the layout to be initialized before
    used. See $init_constants.
  */
  static LAYOUT /ObjectType? := null

  /**
  Initializes the constants that depend on the VM.
  The Program class contains flat arrays that depend on the number of objects.
  Set the object size here instead of depending on the specific layout.
  */
  static init_constants snapshot_program/snapshot.Program:
    ROOT_COUNT = snapshot_program.roots.size
    BUILT_IN_CLASS_ID_COUNT = snapshot_program.built_in_class_ids.size
    ENTRY_POINT_COUNT = snapshot_program.entry_point_indexes.size
    INVOKE_BYTECODE_COUNT = snapshot_program.invoke_bytecode_offsets.size

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
      "_invoke_bytecode_offsets": PrimitiveType.INT * INVOKE_BYTECODE_COUNT,
      "_heap": ToitRawHeap.LAYOUT,
      "_roots": PrimitiveType.POINTER * ROOT_COUNT,
      "_builtin_class_ids": PrimitiveType.POINTER * BUILT_IN_CLASS_ID_COUNT,
      "_entry_point_indexes": PrimitiveType.INT * ENTRY_POINT_COUNT,
      "_source_mapping": PrimitiveType.POINTER,
    }

  snapshot_program /snapshot.Program
  constructor .snapshot_program:

  write_to image/Image -> int:
    word_size := image.word_size
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
    header.fill_into image --at=anchored["header"]

    class_tags := snapshot_program.class_tags
    class_instance_sizes := snapshot_program.class_instance_sizes
    assert: class_tags.size == class_instance_sizes.size
    snapshot_class_bits := List class_tags.size:
      tag := class_tags[it]
      instance_size := class_instance_sizes[it]
      (instance_size << snapshot.Program.CLASS_TAG_SIZE_) | tag

    // Store the large_integer header in the image so we can use it
    // whenever we need to create a large integer.
    large_integer_id := snapshot_program.header.large_integer_id
    large_integer_tag := class_tags[large_integer_id]
    large_integer_header := (large_integer_id << CLASS_TAG_BIT_SIZE) | large_integer_tag
    image.large_integer_header_ = ToitInteger.to_smi_address --word_size=word_size large_integer_header

    class_bits := ToitList snapshot_class_bits --element_type=PrimitiveType.UINT16
    class_bits.fill_into image --at=anchored["class_bits"]

    global_variables := ToitTable snapshot_program.global_variables
    global_variables.fill_into image --at=anchored["global_variables"]

    literals := ToitTable snapshot_program.literals
    literals.fill_into image --at=anchored["literals"]

    root_offset := anchored["_roots"]
    ROOT_COUNT.repeat:
      root_object := ToitHeapObject snapshot_program.roots[it]
      root_address := root_object.write_to image
      root_offset = offheap.put_heap_pointer --at=root_offset root_address
    assert: root_offset == (anchored["_roots"] + (LAYOUT["_roots"].byte_size --word_size=word_size))

    builtin_offset := anchored["_builtin_class_ids"]
    BUILT_IN_CLASS_ID_COUNT.repeat:
      builtin_object := ToitHeapObject snapshot_program.built_in_class_ids[it]
      builtin_address := builtin_object.write_to image
      assert: ToitInteger.is_smi_address builtin_address
      builtin_offset = offheap.put_heap_pointer --at=builtin_offset builtin_address
    assert: builtin_offset == (anchored["_builtin_class_ids"] + (LAYOUT["_builtin_class_ids"].byte_size --word_size=word_size))

    invoke_bytecode_offset := anchored["_invoke_bytecode_offsets"]
    INVOKE_BYTECODE_COUNT.repeat:
      element := snapshot_program.invoke_bytecode_offsets[it]
      invoke_bytecode_offset = offheap.put_int32 --at=invoke_bytecode_offset element
    assert: invoke_bytecode_offset == (anchored["_invoke_bytecode_offsets"] + (LAYOUT["_invoke_bytecode_offsets"].byte_size --word_size=word_size))

    entry_offset := anchored["_entry_point_indexes"]
    ENTRY_POINT_COUNT.repeat:
      entry_index := snapshot_program.entry_point_indexes[it]
      entry_offset = offheap.put_int32 --at=entry_offset entry_index

    class_check_ids := ToitList snapshot_program.class_check_ids
        --element_type=PrimitiveType.UINT16
    class_check_ids.fill_into image --at=anchored["class_check_ids"]

    interface_check_offsets := ToitList snapshot_program.interface_check_selectors
        --element_type=PrimitiveType.UINT16
    interface_check_offsets.fill_into image --at=anchored["interface_check_offsets"]

    dispatch_table := ToitList snapshot_program.dispatch_table
        --element_type=PrimitiveType.INT32
    dispatch_table.fill_into image --at=anchored["dispatch_table"]

    bytecodes := ToitUint8List snapshot_program.all_bytecodes
    bytecodes.fill_into image --at=anchored["bytecodes"]

    // Source mapping is kept at null.

    // Now that we have finished writing the whole image, we can update the
    // '_heap' with the correct values.
    toitheap := ToitRawHeap image.heap
    toitheap.fill_into image --at=anchored["_heap"]

    return address

abstract class ToitSequence:
  static LAYOUT /ObjectType ::= ObjectType {
    "_data": PrimitiveType.POINTER,
    "_length": PrimitiveType.INT,
  }

  fill_into image/Image --at/int:
    element_size := element_byte_size --word_size=image.word_size
    needed_bytes := size * element_size
    address := image.offheap.allocate --bytes=needed_bytes
    write_elements image --at=address

    anchored := LAYOUT.anchor --at=at image.offheap
    anchored.put_offheap_pointer "_data" address
    anchored.put_int32 "_length" size

  write_elements image/Image --at/int:
    element_size := element_byte_size --word_size=image.word_size
    size.repeat: write_element it image --at=(at + it * element_size)

  abstract size -> int
  abstract element_byte_size --word_size/int -> int
  abstract write_element index/int image/Image --at/int -> none


class ToitTable extends ToitSequence:
  static LAYOUT /ObjectType ::= ToitSequence.LAYOUT

  list_ /List

  constructor .list_:

  size: return list_.size
  element_byte_size --word_size/int -> int: return word_size
  write_element index/int image/Image --at/int:
    element := list_[index]
    heap_object := ToitHeapObject element
    object_address := heap_object.write_to image
    image.offheap.put_heap_pointer --at=at object_address

class ToitList extends ToitSequence:
  static LAYOUT /ObjectType ::= ToitSequence.LAYOUT

  list_ /List
  element_type_ /PrimitiveType

  constructor .list_ --element_type/PrimitiveType:
    element_type_ = element_type

  size: return list_.size
  element_byte_size --word_size/int -> int: return element_type_.byte_size --word_size=word_size
  write_element index/int image/Image --at/int:
    offheap := image.offheap
    element := list_[index]
    if element_type_ == PrimitiveType.UINT16:
      image.offheap.put_uint16 --at=at element
    else if element_type_ == PrimitiveType.INT32:
      offheap.put_int32 --at=at element
    else:
      throw "UNIMPLEMENTED"

class ToitUint8List extends ToitSequence:
  static LAYOUT /ObjectType ::= ToitSequence.LAYOUT

  bytes_ /ByteArray

  constructor .bytes_:

  size: return bytes_.size
  element_byte_size --word_size/int -> int: return 1
  write_elements image/Image --at/int:
    image.offheap.put_bytes --at=at  bytes_

  write_element index/int image/Image --at/int: unreachable

class ToitRawHeap:
  static LAYOUT /ObjectType ::= ObjectType {
    "_blocks": ToitMemoryBlockList.LAYOUT,
    "_owner": PrimitiveType.POINTER,
  }

  heap_ /Heap

  constructor .heap_:

  fill_into image/Image --at/int:
    anchored := LAYOUT.anchor image.offheap --at=at
    block_list := ToitMemoryBlockList heap_.blocks_
    block_list.fill_into image --at=anchored["_blocks"]
    // Owner is just `null`.
    anchored.put_offheap_pointer "_owner" 0

class ToitMemoryBlockList:
  static LAYOUT /ObjectType ::= ObjectType {
    "_blocks": ToitMemoryBlockLinkedList.LAYOUT,
    "_length": PrimitiveType.WORD,
  }

  blocks_ /List

  constructor .blocks_:

  fill_into image/Image --at/int:
    anchored := LAYOUT.anchor image.offheap --at=at
    linked_list := ToitMemoryBlockLinkedList blocks_
    linked_list.fill_into image --at=anchored["_blocks"]

    anchored.put_word "_length" blocks_.size

class ToitMemoryBlockLinkedList:
  static LAYOUT /ObjectType ::= ObjectType {
    // Inherited from LinkedList<Block>
    // The anchor is a LinkedListElement, which just contains one element '_next'.
    "_anchor": PrimitiveType.POINTER,
    // Inherited from LinkedFIFO<Block>
    "_tail": PrimitiveType.POINTER,
  }

  blocks_ /List

  constructor .blocks_:

  fill_into image/Image --at/int:
    anchored := LAYOUT.anchor image.offheap --at=at

    next_address := 0  // Last block has "null" as next.
    for i := blocks_.size - 1; i >= 0; i--:
      block /MemoryBlock := blocks_[i]
      toit_block := ToitMemoryBlock block next_address
      address := block.address
      toit_block.fill_into image --at=address
      next_address = address

      if i == blocks_.size - 1:
        // Last block.
        anchored.put_offheap_pointer "_tail" address
      if i == 0:
        // First block == anchor.
        anchored.put_offheap_pointer "_anchor" address


class ToitMemoryBlock:
  // It's debatable, whether the ToitMemoryblock is an ObjectType. It is clearly
  // located in the heap memory, but it is treated like an offheap-object.
  static LAYOUT /ObjectType ::= ObjectType {
    // Inherited from LinkedListElement.
    "_next": PrimitiveType.POINTER,
    "_process": PrimitiveType.POINTER,
    "_top": PrimitiveType.POINTER,
  }

  block_ /MemoryBlock
  next_address_ /int

  constructor .block_ .next_address_:

  fill_into image/Image --at/int:
    // Blocks live in the heap-memory area.
    anchored := LAYOUT.anchor image.heap --at=at
    anchored.put_offheap_pointer "_next" next_address_
    anchored.put_offheap_pointer "_process" 0 // Set process to null.
    anchored.put_offheap_pointer "_top" block_.top_address


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

  constructor.from_subclass_:

  static SMI_TAG_SIZE ::= 1
  static SMI_MASK ::= (1 << SMI_TAG_SIZE) - 1

  static NON_SMI_MASK ::= (1 << 2) - 1
  static HEAP_TAG ::= 1

  static MIN_SMI32_VALUE ::= -(1 << 32 - (SMI_TAG_SIZE + 1))
  static MAX_SMI32_VALUE ::= (1 << 32 - (SMI_TAG_SIZE + 1)) - 1

  static MIN_SMI64_VALUE ::= -(1 << 64 - (SMI_TAG_SIZE + 1))
  static MAX_SMI64_VALUE ::= (1 << 64 - (SMI_TAG_SIZE + 1)) - 1

  static is_heap_object address/int -> bool:
    return (address & NON_SMI_MASK) == HEAP_TAG

  /**
  Writes this object to the image unless the object was already written.
  Returns the encoded address of the written object.
  Returns a Smi (see $ToitInteger.is_smi_address) if the object is an integer
    that fits into a Smi.
  */
  write_to image/Image -> int:
    return image.heap.store o_ --if_absent=:
      encoded_address := write_to_ image
      assert: this is ToitInteger or not ToitInteger.is_smi_address encoded_address
      encoded_address

  abstract o_ -> snapshot.ToitHeapObject

  /**
  Writes this object to the image.
  Returns the encoded address (distinguishing between Smis and pointers).
  */
  abstract write_to_ image/Image -> int

  write_header_to_ image/Image --at/int:
    header_value := ToitInteger.to_smi_address o_.header --word_size=image.word_size
    image.heap.put_word --at=at header_value

  /**
  Smi-encodes the given address.
  */
  to_encoded_address address/int -> int:
    assert: (address & NON_SMI_MASK) == 0
    return address + HEAP_TAG

class ToitArray extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // A length followed by the objects.
    "length": PrimitiveType.WORD,
  }

  o_/snapshot.ToitArray
  constructor .o_: super.from_subclass_

  write_to_ image/Image -> int:
    word_size := image.word_size
    size := o_.content.size
    array_header_byte_size := LAYOUT.byte_size --word_size=word_size
    needed_bytes := array_header_byte_size + (size * word_size)
    address := image.heap.allocate --bytes=needed_bytes
    anchored := LAYOUT.anchor image.heap --at=address

    write_header_to_ image --at=anchored["header"]
    anchored.put_word "length" size

    size.repeat:
      element := o_.content[it]
      element_address := (ToitHeapObject element).write_to image
      element_offset := address + array_header_byte_size + it * word_size
      image.heap.put_heap_pointer --at=element_offset element_address

    return to_encoded_address address

class ToitByteArray extends ToitHeapObject:
  static INTERNAL_SIZE_CUTOFF := Image.PAGE_BYTE_SIZE_32 / 2
  static RAW_BYTE_TAG ::= 0

  static LAYOUT_INTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // A length followed by the bytes.
    "length": PrimitiveType.WORD,
  }

  static LAYOUT_EXTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // A length set to -1-real_length, followed by the external address and a tag.
    "length": PrimitiveType.WORD,
    "external_address": PrimitiveType.POINTER,
    "tag": PrimitiveType.WORD,
  }

  o_/snapshot.ToitByteArray
  constructor .o_: super.from_subclass_

  write_to_ image/Image -> int:
    if o_.content.size > INTERNAL_SIZE_CUTOFF:
      return write_external_to_ image
    return write_internal_to_ image

  write_internal_to_ image/Image -> int:
    word_size := image.word_size
    size := o_.content.size
    byte_array_header_size := LAYOUT_INTERNAL.byte_size --word_size=word_size
    needed_bytes := byte_array_header_size + size
    address := image.heap.allocate --bytes=needed_bytes
    anchored := LAYOUT_INTERNAL.anchor image.heap --at=address

    write_header_to_ image --at=anchored["header"]
    anchored.put_word "length" size
    image.heap.put_bytes --at=(address + byte_array_header_size) o_.content

    return to_encoded_address address

  write_external_to_ image/Image -> int:
    size := o_.content.size
    word_size := image.word_size
    address := image.heap.allocate LAYOUT_EXTERNAL
    anchored := LAYOUT_EXTERNAL.anchor image.heap --at=address

    write_header_to_ image --at=anchored["header"]
    // Encode the size so it is recognized as external byte array.
    anchored.put_word "length" (-1 - size)

    external_address := image.offheap.allocate --bytes=size
    image.offheap.put_bytes --at=external_address o_.content

    anchored.put_offheap_pointer "external_address" external_address

    // A snapshot can only contain raw bytes at the moment.
    anchored.put_word "tag" RAW_BYTE_TAG

    return to_encoded_address address

class ToitString extends ToitHeapObject:
  static INTERNAL_SIZE_CUTOFF := Image.PAGE_BYTE_SIZE_32 / 2

  static LAYOUT_INTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // Internal representation of a string contains a few bits for the
    // hashcode and then the length.
    // The content is following the length.
    "hash_code": PrimitiveType.HALF_WORD,
    "length": PrimitiveType.HALF_WORD,
  }

  static LAYOUT_EXTERNAL /ObjectType ::= ObjectType --packed {  // The '--packed' shouldn't be necessary, but doesn't hurt.
    // Inherited from HeapObject.
    "header": PrimitiveType.WORD,
    // External representation of a string contains a few bits for the
    // hashcode and then the length which is set to -1.
    // It is then followed by the real length and a pointer to the external address.
    "hash_code": PrimitiveType.HALF_WORD,
    "length": PrimitiveType.HALF_WORD,
    "real_length": PrimitiveType.WORD,
    "external_address": PrimitiveType.POINTER,
  }

  o_/snapshot.ToitString
  constructor .o_: super.from_subclass_

  write_to_ image/Image -> int:
    if o_.content.size > INTERNAL_SIZE_CUTOFF:
      return write_external_to_ image
    return write_internal_to_ image

  write_internal_to_ image/Image -> int:
    size := o_.content.size
    null_terminated_size := size + 1
    string_header_byte_size := LAYOUT_INTERNAL.byte_size --word_size=image.word_size
    needed_bytes := string_header_byte_size + null_terminated_size
    address := image.heap.allocate --bytes=needed_bytes
    anchored := LAYOUT_INTERNAL.anchor image.heap --at=address

    write_header_to_ image --at=anchored["header"]

    hash := compute_hash_
    anchored.put_half_word "hash_code" hash
    anchored.put_half_word "length" size
    image.heap.put_bytes --at=(address + string_header_byte_size) o_.content
    // Null terminate the string.
    image.heap.put_uint8 --at=(address + string_header_byte_size + size) 0

    return to_encoded_address address

  write_external_to_ image/Image -> int:
    size := o_.content.size
    null_terminated_size := size + 1
    address := image.heap.allocate LAYOUT_EXTERNAL
    anchored := LAYOUT_EXTERNAL.anchor image.heap --at=address

    write_header_to_ image --at=anchored["header"]

    hash := compute_hash_
    anchored.put_half_word "hash_code" hash

    // External representation has -1 as length.
    anchored.put_half_word "length" -1

    anchored.put_word "real_length" size

    content_address := image.offheap.allocate --bytes=null_terminated_size
    image.offheap.put_bytes --at=content_address o_.content
    // Null terminate.
    image.offheap.put_uint8 --at=(content_address + size) 0

    anchored.put_offheap_pointer "external_address" content_address

    return to_encoded_address address

  // This constant must be kept in sync with objects.cc.
  static NO_HASH_CODE_ ::= 0xFFFF

  compute_hash_ -> int:
    // Keep an assert to detect when we do changes to the way we compute the hash.
    assert: "hello world".hash_code == 64985
    hash := (o_.content.size) & 0xFFFF
    o_.content.do:
      hash = (31 * hash + it) & 0xFFFF
    if hash == NO_HASH_CODE_: hash = 0
    return hash

class ToitOddball extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType {
    "header": PrimitiveType.WORD,
  }

  o_/snapshot.ToitOddball
  constructor .o_: super.from_subclass_

  write_to_ image/Image -> int:
    address := image.heap.allocate LAYOUT
    anchored := LAYOUT.anchor image.heap --at=address
    write_header_to_ image --at=anchored["header"]
    return to_encoded_address address

class ToitInstance extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType {
    // A header followed by the fields.
    "header": PrimitiveType.WORD,
  }

  o_/snapshot.ToitInstance
  constructor .o_: super.from_subclass_

  write_to_ image/Image -> int:
    word_size := image.word_size
    header_byte_size := LAYOUT.byte_size --word_size=word_size
    needed_bytes := header_byte_size + o_.fields.size * word_size
    address := image.heap.allocate --bytes=needed_bytes
    anchored := LAYOUT.anchor image.heap --at=address
    write_header_to_ image --at=anchored["header"]

    o_.fields.size.repeat:
      field := o_.fields[it]
      field_address := (ToitHeapObject field).write_to image
      field_offset := address + header_byte_size + (it * word_size)
      image.heap.put_heap_pointer --at=field_offset field_address

    return to_encoded_address address

class ToitFloat extends ToitHeapObject:
  static LAYOUT /ObjectType ::= ObjectType {
    // A header followed by the 8 byte float value.
    "header": PrimitiveType.WORD,
    "value": PrimitiveType.FLOAT64,
  }

  o_/snapshot.ToitFloat
  constructor .o_: super.from_subclass_

  write_to_ image/Image -> int:
    address := image.heap.allocate LAYOUT
    anchored := LAYOUT.anchor image.heap --at=address
    write_header_to_ image --at=anchored["header"]
    anchored.put_float64 "value" o_.value
    return to_encoded_address address

class ToitInteger extends ToitHeapObject:
  static LAYOUT_LARGE_INTEGER /ObjectType ::= ObjectType {
    // A header followed by the 8 byte integer value.
    "header": PrimitiveType.WORD,
    "value": PrimitiveType.INT64,
  }

  static is_smi_address address/int -> bool:
    return (address & ToitHeapObject.SMI_MASK) == 0

  static is_valid_smi x/int --word_size/int:
    if word_size == 4:
      return ToitHeapObject.MIN_SMI32_VALUE <= x <= ToitHeapObject.MAX_SMI32_VALUE
    return ToitHeapObject.MIN_SMI64_VALUE <= x <= ToitHeapObject.MAX_SMI64_VALUE

  static to_smi_address x/int --word_size/int -> int:
    assert: is_valid_smi x --word_size=word_size
    return x << ToitHeapObject.SMI_TAG_SIZE

  o_/snapshot.ToitInteger
  constructor .o_: super.from_subclass_

  is_valid_smi --word_size/int:
    return is_valid_smi o_.value --word_size=word_size

  to_smi_address --word_size/int -> int:
    return to_smi_address o_.value --word_size=word_size

  write_to_ image/Image -> int:
    word_size := image.word_size
    // ToitIntegers are the only objects that don't have a header.
    assert: o_.header == null
    if is_valid_smi --word_size=word_size:
      return to_smi_address --word_size=word_size

    address := image.heap.allocate LAYOUT_LARGE_INTEGER
    anchored := LAYOUT_LARGE_INTEGER.anchor image.heap --at=address

    header := image.large_integer_header_
    assert: header != null // Must have been set when writing the Program.
    anchored.put_word "header" header
    anchored.put_int64 "value" o_.value
    return to_encoded_address address

build_image snapshot/snapshot.Program word_size/int -> Image:
  ToitProgram.init_constants snapshot
  image := Image snapshot word_size
  program := ToitProgram snapshot
  program.write_to image
  return image
