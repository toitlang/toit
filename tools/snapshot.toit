// Copyright (C) 2019 Toitware ApS.
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

import ar show *
import host.file
import binary show *

// Library for parsing a snapshot file into a useful structure.
/**
# Examples
  ```
  // Parses a snapshot and prints all roots in the snapshot.
  snapshot := ProgramSnapshot.from_file "program.snapshot"
  program := snapshot.decode
  program.roots.do: print it
  ```
**/
class Program:
  header / ProgramHeader ::= ?
  // Program graph.
  roots                     / List ::= ?  // List of ToitObject
  built_in_class_ids        / List ::= ?  // List of integers
  invoke_bytecode_offsets   / List ::= ?  // List of integers
  entry_point_indexes       / List ::= ?  // List of indexes into the dispatch_table
  class_tags                / List ::= ?  // List of class tags
  class_instance_sizes      / List ::= ?  // List of class instance sizes
  methods                   / List ::= ?  // List of ToitMethod. Extracted from the bytecodes.
  global_variables          / List ::= ?  // List of ToitObject
  class_check_ids           / List ::= ?  // Pairs of start/end id for class typechecks.
  interface_check_selectors / List ::= ?  // Selector offsets for interface typechecks.
  dispatch_table            / List ::= ?  // List of method ids
  literals                  / List ::= ?  // List of ToitObject
  heap_objects              / List ::= ?  // List of ToitObject
                                          // Contains all objects extracted from program heap.
  heap32                    / Heap ::= ?
  heap64                    / Heap ::= ?
  all_bytecodes / ByteArray ::= ?

  // Debugging information.
  method_table_  / Map      ::= ?       // Map of MethodInfo

  // Note that the class_table can have more entries than the `class bits` list, as
  //   the debug-information could refer to classes that aren't instantiated, but for
  //   which instance methods are in the snapshot.
  class_table_    / List ::= []         // List of ClassInfo
  primitive_table / List ::= []         // List of PrimitiveModuleInfo
  selector_names_ / Map  ::= {:}        // Map from dispatch-offset to selector name.
  global_table    / List ::= ?          // List of GlobalInfo
  selectors_      / Map  ::= {:}        // Map from location-id to SelectorClass.

  static CLASS_TAG_SIZE_     ::= 4
  static CLASS_TAG_MASK_     ::= (1 << CLASS_TAG_SIZE_) - 1
  static INSTANCE_SIZE_MASK_ ::= (1 << (16 - CLASS_TAG_SIZE_)) - 1


  constructor snapshot/SnapshotBundle:
    snapshot.parse
    header                    = snapshot.program_snapshot.program_segment.header_
    roots                     = snapshot.program_snapshot.program_segment.roots_
    built_in_class_ids        = snapshot.program_snapshot.program_segment.built_in_class_ids_
    invoke_bytecode_offsets   = snapshot.program_snapshot.program_segment.invoke_bytecode_offsets_
    class_tags                = snapshot.program_snapshot.program_segment.class_bits_.map: it & CLASS_TAG_MASK_
    class_instance_sizes      = snapshot.program_snapshot.program_segment.class_bits_.map: it >> CLASS_TAG_SIZE_
    entry_point_indexes       = snapshot.program_snapshot.program_segment.entry_point_indexes_
    global_variables          = snapshot.program_snapshot.program_segment.global_variables_
    class_check_ids           = snapshot.program_snapshot.program_segment.class_check_ids_
    interface_check_selectors = snapshot.program_snapshot.program_segment.interface_check_selectors_
    dispatch_table            = snapshot.program_snapshot.program_segment.dispatch_table_
    literals                  = snapshot.program_snapshot.program_segment.literals_
    heap_objects              = snapshot.program_snapshot.program_segment.heap_objects_
    heap32                    = snapshot.program_snapshot.program_segment.heap32
    heap64                    = snapshot.program_snapshot.program_segment.heap64
    all_bytecodes             = snapshot.program_snapshot.program_segment.bytecodes_
    method_table_             = snapshot.source_map.method_segment.content
    class_table_              = snapshot.source_map.class_segment.content
    primitive_table           = snapshot.source_map.primitive_segment.content
    selector_names_           = snapshot.source_map.selector_names_segment.content
    global_table              = snapshot.source_map.global_segment.content
    selectors_                = snapshot.source_map.selectors_segment.content

    // Create the methods list.
    current_offset := 0
    methods = List method_table_.size:
      method_info := method_table_[current_offset]
      method := ToitMethod all_bytecodes current_offset method_info.bytecode_size
      current_offset += method.allocation_size
      method

  // Extract selector name from the dispatch offset used in invoke virtual byte codes.
  selector_from_dispatch_offset offset/int -> string:
    return selector_from_dispatch_offset offset --if_absent=:"Unknown D$offset"

  selector_from_dispatch_offset offset/int [--if_absent] -> string:
    return selector_names_.get offset --if_absent=if_absent

  method_info_for id/int -> MethodInfo:
    return method_info_for id: throw "Unknown method"

  method_info_for id/int [failure] -> MethodInfo:
    return method_table_.get id --if_absent=(: failure.call id)

  method_name_for id/int -> string:
    return (method_info_for id).name

  method_info_size -> int: return method_table_.size

  class_info_for id/int -> ClassInfo:
    return class_table_[id]

  class_info_for id/int [failure] -> ClassInfo:
    if not 0 <= id < class_table_.size: return failure.call id
    return class_table_[id]

  class_name_for id/int -> string:
    return (class_info_for id).name

  selector_class_for location_id/int -> SelectorClass:
    return selectors_[location_id]

  do --class_infos [block]:
    if class_infos != true: throw "class_infos flag must be true"
    class_table_.do block

  do --method_infos [block]:
    if method_infos != true: throw "method_infos flag must be true"
    method_table_.do --values block

  method_from_absolute_bci absolute_bci/int -> ToitMethod:
    if absolute_bci >= methods.last.id: return methods.last
    index := methods.index_of
        absolute_bci
        --binary_compare=: | a/ToitMethod b/int | a.id.compare_to b
        --if_absent=: | insertion_index |
          // $insertion_index is the place where absolute_bci would need to be
          //   inserted. As such, the previous index contains the method
          //   that contains the absolute_bci.
          insertion_index - 1
    assert: methods[index].id <= absolute_bci < methods[index + 1].id;
    return methods[index]

  primitive_name module_index/int primitive_index/int -> string:
    module := primitive_table[module_index];
    return "$module.name::$module.primitives[primitive_index]"


class SnapshotBundle:
  static MAGIC_NAME / string ::= "toit"
  static MAGIC_CONTENT / string ::= "like a tiger"
  static SNAPSHOT_NAME / string ::= "snapshot"
  static SOURCE_MAP_NAME / string ::= "source-map"

  byte_array ::= ?
  file_name        / string?          ::= ?
  program_snapshot / ProgramSnapshot  ::= ?
  source_map       / SourceMap        ::= ?

  constructor.from_file name/string:
    return SnapshotBundle name (file.read_content name)

  constructor byte_array/ByteArray:
    return SnapshotBundle null byte_array

  constructor .file_name .byte_array/ByteArray:
    if not is_bundle_content byte_array: throw "Invalid snapshot bundle"
    program_snapshot_offsets := extract_ar_offsets_ byte_array SNAPSHOT_NAME
    source_map_offsets := extract_ar_offsets_ byte_array SOURCE_MAP_NAME
    program_snapshot = ProgramSnapshot byte_array program_snapshot_offsets.from program_snapshot_offsets.to
    source_map = SourceMap byte_array source_map_offsets.from source_map_offsets.to

  static is_bundle_content buffer/ByteArray -> bool:
    magic_file_offsets := extract_ar_offsets_ --silent buffer MAGIC_NAME
    if not magic_file_offsets: return false
    magic_content := buffer.copy  magic_file_offsets.from magic_file_offsets.to
    if magic_content.to_string != MAGIC_CONTENT: return false
    return true

  parse -> none:
    program_snapshot.parse

  decode -> Program:
    return Program this

  stringify -> string:
    postfix := file_name ? " ($file_name)" : ""
    return "snapshot: $byte_array.size bytes$postfix\n - $program_snapshot\n - $source_map\n"

  static extract_ar_offsets_ --silent/bool=false byte_array/ByteArray name/string -> ArFileOffsets?:
    ar_reader := ArReader.from_bytes byte_array
    offsets := ar_reader.find --offsets name
    if not offsets:
      if silent: return null
      throw "Invalid snapshot bundle"
    return offsets

class ProgramHeader:
  block_count32 /int
  block_count64 /int
  offheap_pointer_count /int
  offheap_int32_count /int
  offheap_byte_count /int
  back_table_length /int
  large_integer_id /int

  constructor
      .block_count32
      .block_count64
      .offheap_pointer_count
      .offheap_int32_count
      .offheap_byte_count
      .back_table_length
      .large_integer_id:

class ProgramSnapshot:
  program_segment / ProgramSegment ::= ?
  byte_array      / ByteArray      ::= ?
  from            / int            ::= ?
  to              / int            ::= ?

  constructor .byte_array/ByteArray .from/int .to/int:
    header := SegmentHeader byte_array from
    assert: header.content_size == to - from
    program_segment = ProgramSegment byte_array from to

  byte_size: return to - from

  parse -> none:
    program_segment.parse

  stringify -> string:
    return "$program_segment"

class SourceMap:
  method_segment    / MethodSegment    ::= ?
  class_segment     / ClassSegment     ::= ?
  primitive_segment / PrimitiveSegment ::= ?
  global_segment    / GlobalSegment    ::= ?
  selector_names_segment / SelectorNamesSegment ::= ?
  selectors_segment / SelectorsSegment ::= ?
  string_segment    / StringSegment    ::= ?

  constructor byte_array/ByteArray from/int to/int:
    pos := from
    // For typing reasons we first assign to the nullable locals,
    // and then only to the non-nullable fields.
    method_segment_local    / MethodSegment?    := null
    class_segment_local     / ClassSegment?     := null
    primitive_segment_local / PrimitiveSegment? := null
    global_segment_local    / GlobalSegment?    := null
    selector_names_segment_local / SelectorNamesSegment? := null
    selectors_segment_local / SelectorsSegment? := null
    string_segment_local    / StringSegment?    := null
    while pos < to:
      header := SegmentHeader byte_array pos
      // The string segment must be the first one.
      assert: string_segment_local != null or header.is_string_segment
      if header.is_string_segment:
        string_segment_local = StringSegment byte_array pos (pos + header.content_size)
      else if header.is_method_segment:
        method_segment_local = MethodSegment byte_array pos (pos + header.content_size) string_segment_local
      else if header.is_class_segment:
        class_segment_local = ClassSegment byte_array pos (pos + header.content_size) string_segment_local
      else if header.is_primitive_segment:
        primitive_segment_local = PrimitiveSegment byte_array pos (pos + header.content_size) string_segment_local
      else if header.is_global_names_segment:
        global_segment_local = GlobalSegment byte_array pos (pos + header.content_size) string_segment_local
      else if header.is_selector_names_segment:
        selector_names_segment_local = SelectorNamesSegment byte_array pos (pos + header.content_size) string_segment_local
      else if header.is_selectors_segment:
        selectors_segment_local = SelectorsSegment byte_array pos (pos + header.content_size) string_segment_local
      pos += header.content_size

    method_segment    = method_segment_local
    class_segment     = class_segment_local
    primitive_segment = primitive_segment_local
    global_segment    = global_segment_local
    selector_names_segment = selector_names_segment_local
    selectors_segment = selectors_segment_local
    string_segment    = string_segment_local

  stringify -> string:
    return "$method_segment\n - $class_segment\n - $primitive_segment\n - $selector_names_segment"

OBJECT_TAG          ::= 0
IN_TABLE_TAG        ::= 1
BACK_REFERENCE_TAG  ::= 2
POSITIVE_SMI_TAG    ::= 3
NEGATIVE_SMI_TAG    ::= 4

OBJECT_HEADER_WIDTH ::= 3
OBJECT_HEADER_TYPE_MASK ::= (1 << OBJECT_HEADER_WIDTH) - 1

class SegmentHeader:
  static SIZE ::= 8
  tag_ ::= 0
  content_size ::= 0

  constructor byte_array offset:
    tag_         = LITTLE_ENDIAN.uint32 byte_array offset
    content_size = LITTLE_ENDIAN.uint32 byte_array (offset + 4)

  is_program_snapshot:  return tag_ == 70177017
  is_object_snapshot:   return tag_ == 0x70177017
  is_string_segment:    return tag_ == 70177018
  is_method_segment:    return tag_ == 70177019
  is_class_segment:     return tag_ == 70177020
  is_primitive_segment: return tag_ == 70177021
  is_selector_names_segment: return tag_ == 70177022
  is_global_names_segment:   return tag_ == 70177023
  is_selectors_segment: return tag_ == 70177024

  stringify:
    return "$tag_:$content_size"

class Segment:
  byte_array_ ::= ?
  begin_ ::= 0
  end_ ::= 0
  pos_ := 0

  constructor .byte_array_ .begin_ .end_:
    set_offset_ 0

  byte_size:
    return end_ - begin_

  set_offset_ offset:
    pos_ = begin_ + offset

  read_uint16_:
    result := LITTLE_ENDIAN.uint16 byte_array_ pos_
    pos_ += 2
    return result

  read_uint32_:
    result := LITTLE_ENDIAN.uint32 byte_array_ pos_
    pos_ += 4
    return result

  read_int32_:
    result := LITTLE_ENDIAN.int32 byte_array_ pos_
    pos_ += 4
    return result

  read_float_:
    result := byte_array_.to_float --no-big_endian pos_
    pos_ += 8
    return result

  read_byte_:
    return byte_array_[pos_++]

  read_cardinal_:
    result := 0
    byte := read_byte_
    shift := 0
    while byte >= 128:
      result += (byte - 128) << shift
      shift += 7
      byte = read_byte_
    result += byte << shift
    return result

  read_list_int32_ -> List:
    size := read_int32_
    return List size: read_int32_

  read_list_uint16_ -> List:
    size := read_int32_
    return List size: read_uint16_

  read_list_uint8_ -> ByteArray:
    size := read_int32_
    result := ByteArray size
    result.replace 0 byte_array_ pos_ (pos_ + size)
    pos_ += size
    return result

TAG_SIZE ::= 1

class ToitObject:

abstract class ToitHeapObject extends ToitObject:
  static CLASS_TAG_BIT_SIZE/int ::= 4
  static CLASS_TAG_OFFSET/int ::= 0
  static CLASS_TAG_MASK/int ::= (1 << CLASS_TAG_BIT_SIZE) - 1

  static CLASS_ID_BIT_SIZE/int ::= 10
  static CLASS_ID_OFFSET/int ::= CLASS_TAG_OFFSET + CLASS_TAG_BIT_SIZE
  static CLASS_ID_MASK/int ::= (1 << CLASS_ID_BIT_SIZE) - 1

  header/int? := null
  hash_id_/int

  static HASH_COUNTER_ := 0

  constructor:
    hash_id_ = HASH_COUNTER_++

  class_id -> int:
    assert: header
    return (header >> CLASS_ID_OFFSET) & CLASS_ID_MASK

  class_tag -> int:
    assert: header
    return (header >> CLASS_TAG_OFFSET) & CLASS_TAG_MASK

  hash_code -> int: return hash_id_

  abstract read_from heap_segment/HeapSegment optional_length/int
  abstract store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none

  static HEADER_WORD_SIZE / int ::= 1  // The header (class id and class tag).

class ToitArray extends ToitHeapObject:
  static TAG ::= 0  // Must match TypeTag enum in objects.h.
  // Includes the length, but not the elements.
  static ARRAY_HEADER_WORD_SIZE ::= ToitHeapObject.HEADER_WORD_SIZE + 1
  content := []

  read_from heap_segment optional_length:
    content = List optional_length: heap_segment.read_object_

  store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none:
    words := ARRAY_HEADER_WORD_SIZE + optional_length
    heap32.store this words 0
    if heap64: heap64.store this words 0

class ToitByteArray extends ToitHeapObject:
  static SNAPSHOT_INTERNAL_SIZE_CUTOFF ::= (Heap.PAGE_WORD_SIZE_32 * 4) >> 2
  // Includes the length. But not the following bytes.
  static INTERNAL_WORD_SIZE ::= ToitHeapObject.HEADER_WORD_SIZE + 1
  // Length, address, tag.
  static EXTERNAL_WORD_SIZE ::= ToitHeapObject.HEADER_WORD_SIZE + 3
  static TAG ::= 5  // Must match TypeTag enum in objects.h.
  content /ByteArray := ByteArray 0

  read_from heap_segment optional_length:
    if optional_length > SNAPSHOT_INTERNAL_SIZE_CUTOFF:
      content = heap_segment.read_list_uint8_
    else:
      content = ByteArray optional_length: heap_segment.read_cardinal_

  store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none:
    word_size := ?
    extra_bytes := ?
    if optional_length > SNAPSHOT_INTERNAL_SIZE_CUTOFF:
      word_size = EXTERNAL_WORD_SIZE
      extra_bytes = 0
    else:
      word_size = INTERNAL_WORD_SIZE
      extra_bytes = optional_length
    heap32.store this word_size extra_bytes
    if heap64: heap64.store this word_size extra_bytes


class ToitMethod:
  static HEADER_SIZE ::= 4

  static METHOD ::= 0
  static LAMBDA ::= 1
  static BLOCK ::= 2
  static FIELD_ACCESSOR ::= 3

  id     ::= 0
  arity  ::= 0
  kind   ::= 0
  max_height ::= 0
  value  ::= 0
  bytecodes / ByteArray := ?

  constructor all_bytecodes/ByteArray at/int bytecode_size/int:
    id = at
    arity = all_bytecodes[at++]
    kind_height := all_bytecodes[at++]
    kind       = kind_height & 0x3
    max_height = (kind_height >> 2) * 4
    value = LITTLE_ENDIAN.int16 all_bytecodes at
    at += 2
    assert: at - id == HEADER_SIZE
    bytecodes = all_bytecodes.copy at (at + bytecode_size)

  is_normal_method -> bool: return kind == METHOD
  is_lambda -> bool: return kind == LAMBDA
  is_block -> bool: return kind == BLOCK
  is_field_accessor -> bool: return kind == FIELD_ACCESSOR

  allocation_size -> int:
    return HEADER_SIZE + bytecodes.size

  selector_offset:
    return value

  bci_from_absolute_bci absolute_bci/int -> int:
    bci := absolute_bci - id - HEADER_SIZE
    assert: 0 <= bci < bytecodes.size
    return bci

  absolute_bci_from_bci bci/int -> int:
    assert: 0 <= bci < bytecodes.size
    return bci + id + HEADER_SIZE

  // bytecode_string is static to support future byte code tracing.
  static bytecode_string method/ToitMethod bci index program/Program:
    opcode := method.bytecodes[bci]
    bytecode := BYTE_CODES[opcode]
    line := "[$(%03d opcode)] - $bytecode.description"
    format := bytecode.format
    if format == OP:
    else if format  == OP_BU:
      line += " $index "
    else if format == OP_SU:
      line += " $(method.uint16 bci + 1)"
    else if format == OP_BS:
      line += " S$index "
    else if format == OP_SS:
      line += " S$(method.uint16 bci + 1) "
    else if format == OP_BL:
      line += " $program.literals[index]"
    else if format == OP_SL:
      line += " $program.literals[method.uint16 bci + 1]"
    else if format == OP_BC:
      line += " $(program.class_name_for index)"
    else if format == OP_SC:
      line += " $(program.class_name_for (method.uint16 bci + 1))"
    else if format == OP_BG:
      line += " G$index"
    else if format == OP_SG:
      line += " G$(method.uint16 bci + 1)"
    else if format == OP_BF:
      line += " T$(bci + index)"
    else if format == OP_SF:
      line += " T$(bci + (method.uint16 bci + 1))"
    else if format == OP_BB:
      line += " T$(bci - index)"
    else if format == OP_SB:
      line += " T$(bci - (method.uint16 bci + 1))"
    else if format == OP_BCI:
      is_nullable := (index & 1) != 0
      class_index := index >> 1
      start_id := program.class_check_ids[class_index * 2]
      end_id   := program.class_check_ids[class_index * 2 + 1]
      start_name := program.class_name_for start_id
      line += " $start_name$(is_nullable ? "?" : "")($start_id - $end_id)"
    else if format == OP_SCI:
      index = method.uint16 bci + 1
      is_nullable := (index & 1) != 0
      class_index := index >> 1
      start_id := program.class_check_ids[class_index * 2]
      end_id   := program.class_check_ids[class_index * 2 + 1]
      start_name := program.class_name_for start_id
      line += " $start_name$(is_nullable ? "?" : "")($start_id - $end_id)"
    else if format == OP_BII:
      is_nullable := (index & 1) != 0
      selector_index := index >> 1
      selector_offset := program.interface_check_selectors[selector_index]
      selector_name := program.selector_from_dispatch_offset selector_offset
      line += " $selector_name$(is_nullable ? "?" : "")"
    else if format == OP_SII:
      index = method.uint16 bci + 1
      is_nullable := (index & 1) != 0
      selector_index := index >> 1
      selector_offset := program.interface_check_selectors[selector_index]
      selector_name := program.selector_from_dispatch_offset selector_offset
      line += " $selector_name$(is_nullable ? "?" : "")"
    else if format == OP_BLC:
      local := index >> 5
      class_index := index & 0x1F
      start_id := program.class_check_ids[class_index * 2]
      end_id   := program.class_check_ids[class_index * 2 + 1]
      start_name := program.class_name_for start_id
      line += " $local - $start_name($start_id - $end_id)"
    else if format == OP_SD:
      dispatch_index := method.uint16 bci + 1
      target := program.dispatch_table[dispatch_index]
      debug_info := program.method_info_for target
      line += " $(debug_info.short_stringify program)"
    else if format == OP_SO:
      offset := method.uint16 bci + 1
      line += " $(program.selector_from_dispatch_offset offset)"
    else if format == OP_WU:
      line += " $(method.uint32 bci + 1)"
    else if format == OP_BS_BU:
      line += " S$index $(method.bytecodes[bci+2])"
    else if format == OP_BS_SO:
      offset := method.uint16 bci + 2
      line += " $(program.selector_from_dispatch_offset offset)"
    else if format == OP_BU_SO:
      offset := method.uint16 bci + 2
      line += " $(program.selector_from_dispatch_offset offset)"
    else if format == OP_BU_SU:
      if bytecode.name == "PRIMITIVE":
        primitive_index := method.uint16 bci + 2
        name := program.primitive_name index primitive_index
        line += " {$name}"
      else:
        line += " $index $(method.uint16 bci + 2)"
    else if format == OP_BU_WU:
      height := index
      target_absolute_bci := method.uint32 bci + 2
      target_method := program.method_from_absolute_bci target_absolute_bci
      target_bci := target_method.bci_from_absolute_bci target_absolute_bci
      target_method_info := program.method_info_for target_method.id: null
      target_name := target_method_info and (target_method_info.prefix_string program)
      line += " {$target_name:$target_bci}"
    else if format == OP_SS_SO:
      offset := method.uint16 bci + 3
      line += " $(program.selector_from_dispatch_offset offset)"
    else if format == OP_SU_SU:
      arity := method.uint16 bci + 1
      height := method.uint16 bci + 3
      line += " $arity $height"
    else if format == OP_SD_BS_BU:
      dispatch_index := method.uint16 bci + 1
      height := method.uint8 bci + 3
      arity := method.uint8 bci + 4
      target := program.dispatch_table[dispatch_index]
      debug_info := program.method_info_for target
      line += " $(debug_info.short_stringify program) S$height $arity"
    else:
      line += "UNKNOWN FORMAT"
    return line

  // Helper method to extract values from bytecode stream.
  uint8 offset: return LITTLE_ENDIAN.uint8 bytecodes offset

  // Helper method to extract values from bytecode stream.
  uint16 offset: return LITTLE_ENDIAN.uint16 bytecodes offset

  // Helper method to extract values from bytecode stream.
  uint32 offset: return LITTLE_ENDIAN.uint32 bytecodes offset

  do_call bci index program/Program [block]:
    opcode := bytecodes[bci]
    bytecode := BYTE_CODES[opcode]
    format := bytecode.format
    if format == OP_SD:
      target := program.dispatch_table[uint16 bci + 1]
      debug_info := program.method_info_for target
      block.call debug_info.name
    else if format == OP_SO:
      block.call
        program.selector_from_dispatch_offset
          uint16 bci + 1
    else if format == OP_BS_SO:
      block.call
        program.selector_from_dispatch_offset
          uint16 bci + 2
    else if format == OP_BU_SO:
      block.call
        program.selector_from_dispatch_offset
          uint16 bci + 2

  do_calls program [block]:
    effective := 0
    index := 0
    length := bytecodes.size
    while index < length:
      opcode := bytecodes[index]
      bc_length := BYTE_CODES[opcode].size
      if bc_length > 1:
        argument := bytecodes[index + 1]
        effective = (effective << 8) | argument;
      do_call index effective program block
      if opcode != 0: effective = 0;
      index += bc_length

  do_bytecodes [block]:
    index := 0
    length := bytecodes.size
    while index < length:
      opcode := bytecodes[index]
      block.call BYTE_CODES[opcode] index
      bc_length := BYTE_CODES[opcode].size
      index += bc_length

  output program/Program:
    debug_info := program.method_info_for id
    print "$id: $(debug_info.short_stringify program)"
    index := 0
    length := bytecodes.size
    while index < length:
      absolute_bci := absolute_bci_from_bci index
      line := "$(%3d index)/$(%4d absolute_bci) "
      opcode := bytecodes[index]
      bc_length := BYTE_CODES[opcode].size
      argument := 0;
      if bc_length > 1:
        argument = bytecodes[index + 1]
      line += bytecode_string this index argument program
      print line
      index += bc_length
    print ""

  hash_code:
    return id

  operator == other:
    return other is ToitMethod and other.id == id

  stringify program/Program:
    debug_info := program.method_info_for id
    return debug_info.short_stringify

  stringify:
    return "Method $id"

// Bytecode formats
OP       ::=  1
OP_BU    ::=  2
OP_BS    ::=  3
OP_BL    ::=  4
OP_BC    ::=  5
OP_BG    ::=  6
OP_BF    ::=  7
OP_BB    ::=  8
OP_BCI   ::=  9
OP_BII   ::= 10
OP_BLC   ::= 11
OP_SU    ::= 12
OP_SF    ::= 13
OP_BS_BU ::= 14
OP_SD    ::= 15
OP_SO    ::= 16
OP_WU    ::= 17
OP_BS_SO ::= 18
OP_BU_SO ::= 19
OP_BU_SU ::= 20
OP_BU_WU ::= 21
OP_SD_BS_BU ::= 22
OP_SS    ::= 23
OP_SL    ::= 24
OP_SG    ::= 25
OP_SC    ::= 26
OP_SS_SO ::= 27
OP_SCI   ::= 28
OP_SII   ::= 29
OP_SB    ::= 30
OP_SU_SU ::= 31

class Bytecode:
  name        ::= ""
  size        ::= 0
  format      ::= 0
  description ::= ""

  constructor .name .size .format .description:

// TODO(Lau): Fix alignment.
BYTE_CODES ::= [
  Bytecode "LOAD_LOCAL"                 2 OP_BS "load local",
  Bytecode "LOAD_LOCAL_WIDE"            3 OP_SS "load local wide",
  Bytecode "POP_LOAD_LOCAL"             2 OP_BS "pop, load local",
  Bytecode "STORE_LOCAL"                2 OP_BS "store local",
  Bytecode "STORE_LOCAL_POP"            2 OP_BS "store local, pop",
  Bytecode "LOAD_OUTER"                 2 OP_BS "load outer",
  Bytecode "STORE_OUTER"                2 OP_BS "store outer",
  Bytecode "LOAD_FIELD"                 2 OP_BU "load field",
  Bytecode "LOAD_FIELD_WIDE"            3 OP_SU "load field wide",
  Bytecode "LOAD_FIELD_LOCAL"           2 OP_BU "load field local",
  Bytecode "POP_LOAD_FIELD_LOCAL"       2 OP_BU "pop, load field local",
  Bytecode "STORE_FIELD"                2 OP_BU "store field",
  Bytecode "STORE_FIELD_WIDE"           3 OP_SU "store field wide",
  Bytecode "STORE_FIELD_POP"            2 OP_BU "store field, pop",
  Bytecode "LOAD_LOCAL_0"               1 OP "load local 0",
  Bytecode "LOAD_LOCAL_1"               1 OP "load local 1",
  Bytecode "LOAD_LOCAL_2"               1 OP "load local 2",
  Bytecode "LOAD_LOCAL_3"               1 OP "load local 3",
  Bytecode "LOAD_LOCAL_4"               1 OP "load local 4",
  Bytecode "LOAD_LOCAL_5"               1 OP "load local 5",
  Bytecode "LOAD_LITERAL"               2 OP_BL "load literal",
  Bytecode "LOAD_LITERAL_WIDE"          3 OP_SL "load literal wide",
  Bytecode "LOAD_NULL"                  1 OP "load null",
  Bytecode "LOAD_SMI_0"                 1 OP "load smi 0",
  Bytecode "LOAD_8_SMI_0"               1 OP "load 8 smi 0",
  Bytecode "LOAD_SMI_1"                 1 OP "load smi 1",
  Bytecode "LOAD_SMI_U8"                2 OP_BU "load smi",
  Bytecode "LOAD_SMI_U16"               3 OP_SU "load smi",
  Bytecode "LOAD_SMI_U32"               5 OP_WU "load smi",
  Bytecode "LOAD_GLOBAL_VAR"            2 OP_BG "load global var",
  Bytecode "LOAD_GLOBAL_VAR_DYNAMIC"    1 OP    "store global var dynamic",
  Bytecode "LOAD_GLOBAL_VAR_WIDE"       3 OP_SG "load global var wide",
  Bytecode "LOAD_GLOBAL_VAR_LAZY"       2 OP_BG "load global var lazy",
  Bytecode "LOAD_GLOBAL_VAR_LAZY_WIDE"  3 OP_BG "load global var lazy wide",
  Bytecode "STORE_GLOBAL_VAR"           2 OP_BG "store global var",
  Bytecode "STORE_GLOBAL_VAR_WIDE"      3 OP_SG "store global var wide",
  Bytecode "STORE_GLOBAL_VAR_DYNAMIC"   1 OP "store global var dynamic",
  Bytecode "LOAD_BLOCK"                 2 OP_BU "load block",
  Bytecode "LOAD_OUTER_BLOCK"           2 OP_BU "load outer block",
  Bytecode "POP"                        2 OP_BU "pop",
  Bytecode "POP_1"                      1 OP "pop 1",
  Bytecode "ALLOCATE"                   2 OP_BC "allocate instance",
  Bytecode "ALLOCATE_WIDE"              3 OP_SC "allocate instance wide",
  Bytecode "IS_CLASS"                   2 OP_BCI "is class",
  Bytecode "IS_CLASS_WIDE"              3 OP_SCI "is class wide",
  Bytecode "IS_INTERFACE"               2 OP_BII "is interface",
  Bytecode "IS_INTERFACE_WIDE"          3 OP_SII "is interface wide",
  Bytecode "AS_CLASS"                   2 OP_BCI "as class",
  Bytecode "AS_CLASS_WIDE"              3 OP_SCI "as class wide",
  Bytecode "AS_INTERFACE"               2 OP_BII "as interface",
  Bytecode "AS_INTERFACE_WIDE"          3 OP_SII "as interface wide",
  Bytecode "AS_LOCAL"                   2 OP_BLC "load local, as class, pop",
  Bytecode "INVOKE_STATIC"              3 OP_SD "invoke static",
  Bytecode "INVOKE_STATIC_TAIL"         5 OP_SD_BS_BU "invoke static tail",
  Bytecode "INVOKE_BLOCK"               2 OP_BS "invoke block",
  Bytecode "INVOKE_LAMBDA_TAIL"         2 OP_BF "invoke lambda tail",
  Bytecode "INVOKE_INITIALIZER_TAIL"    3 OP_BS_BU "invoke initializer tail",
  Bytecode "INVOKE_VIRTUAL"             4 OP_BS_SO "invoke virtual",
  Bytecode "INVOKE_VIRTUAL_WIDE"        5 OP_SS_SO "invoke virtual wide",
  Bytecode "INVOKE_VIRTUAL_GET"         3 OP_SO "invoke virtual get",
  Bytecode "INVOKE_VIRTUAL_SET"         3 OP_SO "invoke virtual set",
  Bytecode "INVOKE_EQ"                  1 OP "invoke eq",
  Bytecode "INVOKE_LT"                  1 OP "invoke lt",
  Bytecode "INVOKE_GT"                  1 OP "invoke gt",
  Bytecode "INVOKE_LTE"                 1 OP "invoke lte",
  Bytecode "INVOKE_GTE"                 1 OP "invoke gte",
  Bytecode "INVOKE_BIT_OR"              1 OP "invoke bit or",
  Bytecode "INVOKE_BIT_XOR"             1 OP "invoke bit xor",
  Bytecode "INVOKE_BIT_AND"             1 OP "invoke bit and",
  Bytecode "INVOKE_BIT_SHL"             1 OP "invoke bit shl",
  Bytecode "INVOKE_BIT_SHR"             1 OP "invoke bit shr",
  Bytecode "INVOKE_BIT_USHR"            1 OP "invoke bit ushr",
  Bytecode "INVOKE_ADD"                 1 OP "invoke add",
  Bytecode "INVOKE_SUB"                 1 OP "invoke sub",
  Bytecode "INVOKE_MUL"                 1 OP "invoke mul",
  Bytecode "INVOKE_DIV"                 1 OP "invoke div",
  Bytecode "INVOKE_MOD"                 1 OP "invoke mod",
  Bytecode "INVOKE_AT"                  1 OP "invoke at",
  Bytecode "INVOKE_AT_PUT"              1 OP "invoke at_put",
  Bytecode "BRANCH"                     3 OP_SF "branch",
  Bytecode "BRANCH_IF_TRUE"             3 OP_SF "branch if true",
  Bytecode "BRANCH_IF_FALSE"            3 OP_SF "branch if false",
  Bytecode "BRANCH_BACK"                2 OP_BB "branch back",
  Bytecode "BRANCH_BACK_WIDE"           3 OP_SB "branch back wide",
  Bytecode "BRANCH_BACK_IF_TRUE"        2 OP_BB "branch back if true",
  Bytecode "BRANCH_BACK_IF_TRUE_WIDE"   3 OP_SB "branch back if true wide",
  Bytecode "BRANCH_BACK_IF_FALSE"       2 OP_BB "branch back if false",
  Bytecode "BRANCH_BACK_IF_FALSE_WIDE"  3 OP_SB "branch back if false wide",
  Bytecode "PRIMITIVE"                  4 OP_BU_SU "invoke primitive",
  Bytecode "THROW"                      2 OP_BU "throw",
  Bytecode "RETURN"                     3 OP_BS_BU "return",
  Bytecode "RETURN_NULL"                3 OP_BS_BU "return null",
  Bytecode "NON_LOCAL_RETURN"           2 OP_BU "non-local return",
  Bytecode "NON_LOCAL_RETURN_WIDE"      2 OP_BU_SU "non-local return wide",
  Bytecode "NON_LOCAL_BRANCH"           6 OP_BU_WU "non-local branch",
  Bytecode "LINK"                       2 OP_BU "link try",
  Bytecode "UNLINK"                     2 OP_BU "unlink try",
  Bytecode "UNWIND"                     1 OP "unwind",
  Bytecode "HALT"                       2 OP_BU "halt",
  Bytecode "INTRINSIC_SMI_REPEAT"       1 OP "intrinsic smi repeat",
  Bytecode "INTRINSIC_ARRAY_DO"         1 OP "intrinsic array do",
  Bytecode "INTRINSIC_HASH_FIND"        1 OP "intrinsic hash find",
  Bytecode "INTRINSIC_HASH_DO"          1 OP "intrinsic hash do",
]


class ToitString extends ToitHeapObject:
  // in heap content:  [class:w][hash_code:h][length:h][content:byte*length][0][padding]
  // off heap content: [class:w][hash_code:h][-1:h]    [length:w][external_address:w]

  static SNAPSHOT_INTERNAL_SIZE_CUTOFF ::= (Heap.PAGE_WORD_SIZE_32 * 4) >> 2

  // hash+length.
  // It is then followed by the string and a terminating '\0'.
  static INTERNAL_WORD_SIZE ::= ToitHeapObject.HEADER_WORD_SIZE + 1
  // Internal + actual-length, address.
  static EXTERNAL_WORD_SIZE ::= INTERNAL_WORD_SIZE + 2

  static TAG ::= 1  // Must match TypeTag enum in objects.h.

  content/ByteArray? := null

  read_from heap_segment optional_length:
    if optional_length > SNAPSHOT_INTERNAL_SIZE_CUTOFF:
      null_terminated := heap_segment.read_list_uint8_
      content = null_terminated[..null_terminated.size - 1]
    else:
      content = ByteArray optional_length: heap_segment.read_byte_

  store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none:
    word_size := ?
    extra_bytes := ?
    if optional_length > SNAPSHOT_INTERNAL_SIZE_CUTOFF:
      word_size = EXTERNAL_WORD_SIZE
      extra_bytes = 0
    else:
      word_size = INTERNAL_WORD_SIZE
      // Content, and a terminating '\0'.
      extra_bytes = optional_length + 1
    heap32.store this word_size extra_bytes
    if heap64: heap64.store this word_size extra_bytes

  stringify:
    return content.to_string


class ToitOddball extends ToitHeapObject:
  static TAG ::= 3  // Must match TypeTag enum in objects.h.

  stringify:
    return "Oddball (true/false/null)"

  store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none:
    header_size := ToitHeapObject.HEADER_WORD_SIZE
    heap32.store this header_size 0
    if heap64: heap64.store this header_size 0

  read_from heap_segment optional_length:


class ToitInstance extends ToitHeapObject:
  static TAG ::= 2  // Must match TypeTag enum in objects.h.

  fields := []

  read_from heap_segment optional_length:
    field_count := heap_segment.read_cardinal_
    fields = List field_count: heap_segment.read_object_

  store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none:
    word_count := ToitHeapObject.HEADER_WORD_SIZE + optional_length
    heap32.store this word_count 0
    if heap64: heap64.store this word_count 0


class ToitFloat extends ToitHeapObject:
  static TAG ::= 4  // Must match TypeTag enum in objects.h.

  value := 0.0

  read_from heap_segment optional_length:
    value = heap_segment.read_float_

  store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none:
    word_count := ToitHeapObject.HEADER_WORD_SIZE
    extra_bytes := 8
    heap32.store this word_count extra_bytes
    if heap64: heap64.store this word_count extra_bytes

  stringify:
    return "$value"


class ToitInteger extends ToitHeapObject:
  value ::= 0

  constructor .value:

  stringify:
    return "$value"

  hash_code:
    return value

  operator == other:
    return other is ToitInteger and other.value == value


  static MIN_SMI32_VALUE ::= -(1 << (32 - (TAG_SIZE + 1)))
  static MAX_SMI32_VALUE ::= (1 << (32 - (TAG_SIZE + 1))) - 1
  static is_valid32 v:
    return MIN_SMI32_VALUE <= v <= MAX_SMI32_VALUE

  static MIN_SMI64_VALUE ::= -(1 << (64 - (TAG_SIZE + 1)))
  static MAX_SMI64_VALUE ::= (1 << (64 - (TAG_SIZE + 1))) - 1
  static is_valid64 v:
    return MIN_SMI64_VALUE <= v <= MAX_SMI64_VALUE

  store_in_heaps heap32/Heap heap64/Heap? optional_length/int -> none:
    word_count := ToitHeapObject.HEADER_WORD_SIZE
    extra_bytes := 8
    heap32.store this word_count extra_bytes
    if heap64: heap64.store this word_count extra_bytes

  read_from heap_segment optional_length: unreachable

/**
A simulated heap.
Contains a mapping from offset to object.
*/
class Heap:
  static PAGE_WORD_SIZE_32 / int ::= 1 << 10
  static PAGE_WORD_SIZE_64 / int ::= 1 << 12
  // Each block reserves 2 words for the `Block` object.
  static BLOCK_HEADER_WORD_SIZE / int ::= 2

  /// Word size in bytes.
  /// Must be either 4 or 8.
  word_size / int ::= ?

  /// Map from offset to Heap-object.
  offsets_ / Map ::= {:}

  current_byte_offset_ / int:= 0
  remaining_words_in_block_ / int := 0

  constructor .word_size:

  /// Stores the given $object in the heap.
  /// The object's size is given in $words and extra $bytes.
  ///
  /// The object might not be fully initialized yet (which is another reason
  ///   we want the $words and $bytes, instead of asking the object directly).
  store object/ToitHeapObject words/int bytes/int -> none:
    aligned_word_size := total_words_ words bytes
    if remaining_words_in_block_ < aligned_word_size:
      // Discard the rest of the block.
      allocate_ remaining_words_in_block_
      remaining_words_in_block_ = word_size == 4 ? PAGE_WORD_SIZE_32 : PAGE_WORD_SIZE_64
      allocate_ BLOCK_HEADER_WORD_SIZE
    object_offset := allocate_ aligned_word_size
    offsets_[object_offset] = object

  /// Returns the object at the given heap offset.
  object_at offset/int -> ToitHeapObject:
    return offsets_[offset]

  /** Computes the fully aligned size of an object with the given $words and extra $bytes. */
  total_words_ words bytes -> int:
    aligned_extra_bytes := (bytes + (word_size - 1) & ~(word_size - 1))
    return words + (aligned_extra_bytes / word_size)

  /// Updates the current offset and the remaining size in the block.
  /// Returns the old byte offset.
  allocate_ words / int -> int:
    assert: remaining_words_in_block_ >= words
    result := current_byte_offset_
    remaining_words_in_block_ -= words
    current_byte_offset_ += words * word_size
    return result

abstract class HeapSegment extends Segment:
  back_table_   / List ::= []
  // Collected for easier iteration.
  heap_objects_ / List ::= []

  heap32 / Heap ::= Heap 4
  heap64 / Heap ::= Heap 8

  constructor byte_array begin end:
    super byte_array begin end

  parsed_ := false
  parse_result := null

  parse [block]:
    if not parsed_:
      parse_result = block.call
      parsed_ = true
    return parse_result

  read_integer_ is_non_negative:
    value := read_cardinal_
    result_value := is_non_negative ? value : -value
    result := ToitInteger result_value
    if not ToitInteger.is_valid64 result_value:
      store_in_heap_ result 0
    else if not ToitInteger.is_valid32 result_value:
      store_in_heap_ --only32 result 0
    return result

  allocate_object_ tag -> ToitHeapObject:
    if tag == ToitArray.TAG:     return ToitArray
    if tag == ToitByteArray.TAG: return ToitByteArray
    if tag == ToitString.TAG:    return ToitString
    if tag == ToitOddball.TAG:   return ToitOddball
    if tag == ToitInstance.TAG:  return ToitInstance
    if tag == ToitFloat.TAG:     return ToitFloat
    throw "Unknown Toit object tag: $tag"

  read_object_ -> ToitObject:
    header := read_cardinal_
    type := header & OBJECT_HEADER_TYPE_MASK
    extra := header >> OBJECT_HEADER_WIDTH
    if type == NEGATIVE_SMI_TAG: return read_integer_ false
    if type == POSITIVE_SMI_TAG: return read_integer_ true
    if type == BACK_REFERENCE_TAG: return get_back_reference_ extra
    assert: (type == OBJECT_TAG) or (type == IN_TABLE_TAG)
    in_table := type == IN_TABLE_TAG
    optional_length := extra
    heap_tag := read_byte_
    result := allocate_object_ heap_tag
    store_in_heap_ result optional_length
    heap_objects_.add result
    if in_table: back_table_.add result
    result.header = (read_object_ as ToitInteger).value
    result.read_from this optional_length
    return result

  store_in_heap_ --only32/bool=false object/ToitHeapObject optional_length/int:
    object.store_in_heaps
        heap32
        only32 ? null : heap64
        optional_length

  get_back_reference_ index/int -> ToitObject: return back_table_[index]

  abstract get_program_heap_reference_ id -> ToitObject

class ProgramSegment extends HeapSegment:
  header_ /ProgramHeader?    := null
  roots_                     := []
  built_in_class_ids_        := []
  invoke_bytecode_offsets_   := []
  entry_point_indexes_       := []
  class_bits_                := []
  global_variables_          := []
  literals_                  := []
  class_check_ids_           := []
  interface_check_selectors_ := []
  dispatch_table_            := []
  bytecodes_                 := null

  constructor byte_array begin end:
    super byte_array begin end

  parse -> none:
    super: read_program_

  parse_header_:
    encoded_normal_block_count := read_uint32_
    block_count32 := encoded_normal_block_count >> 16
    block_count64 := encoded_normal_block_count & 0xFFFF
    offheap_pointer_count := read_uint32_
    offheap_int32_count   := read_uint32_
    offheap_byte_count    := read_uint32_
    back_table_length     := read_uint32_
    large_integer_id      := read_uint32_
    header_ = ProgramHeader
        block_count32
        block_count64
        offheap_pointer_count
        offheap_int32_count
        offheap_byte_count
        back_table_length
        large_integer_id
    return back_table_length

  read_program_:
    set_offset_ SegmentHeader.SIZE
    back_table_length := parse_header_
    class_bits_                = read_list_uint16_
    global_variables_          = List read_cardinal_: read_object_
    literals_                  = List read_cardinal_: read_object_
    roots_                     = List read_cardinal_: read_object_
    built_in_class_ids_        = List read_cardinal_: read_object_
    invoke_bytecode_offsets_   = List read_cardinal_: read_cardinal_ - 1
    entry_point_indexes_       = List read_cardinal_: read_cardinal_
    class_check_ids_           = read_list_uint16_
    interface_check_selectors_ = read_list_uint16_
    dispatch_table_            = read_list_int32_
    bytecodes_                 = read_list_uint8_
    if back_table_.size != back_table_length:
      throw "Bad back-table size"

  get_program_heap_reference_ offset -> ToitObject:
    throw "Program heaps must not have program heap references"

  stringify:
    return "program: $byte_size bytes"


class Position:
  line ::= -1
  column ::= -1

  constructor .line .column:

  stringify:
    return "$line:$column"


class MethodInfo:
  id /int ::= ?
  bytecode_size /int ::= ?
  name /string ::= ?
  type /int ::= ?
  outer /int? ::= ?
  holder_name /string? ::= ?
  absolute_path /string ::= ?
  error_path /string ::= ?
  position /Position ::= ?
  bytecode_positions /Map ::= ?  // of bytecode to Position
  as_class_names /Map ::= ?      // of bytecode to strings
  pubsub_info /List ::= ?


  static INSTANCE_TYPE      ::= 0
  static GLOBAL_TYPE        ::= 1
  static LAMBDA_TYPE        ::= 2
  static BLOCK_TYPE         ::= 3
  static TOP_LEVEL_TYPE     ::= 4

  short_stringify program/Program:
    prefix := prefix_string program
    return "$prefix $error_path:$position"

  position relative_bci/int -> Position:
    return bytecode_positions.get relative_bci --if_absent=: position

  as_class_name relative_bci/int -> string:
    return as_class_names.get relative_bci --if_absent=: "<unknown>"

  print program/Program:
    print (stringify program)

  constructor .id .bytecode_size .name .type .outer .holder_name .absolute_path .error_path \
      .position .bytecode_positions .as_class_names .pubsub_info:

  stacktrace_string program/Program:
    if type == BLOCK_TYPE:
      info := program.method_info_for outer
      return "$(info.stacktrace_string program).<block>"

    if type == LAMBDA_TYPE:
      info := program.method_info_for outer
      return "$(info.stacktrace_string program).<lambda>"

    return prefix_string program

  prefix_string program/Program:
    if type == BLOCK_TYPE:
      info := program.method_info_for outer
      return "[block] in $(info.prefix_string program)"

    if type == LAMBDA_TYPE:
      info := program.method_info_for outer
      return "[lambda] in $(info.prefix_string program)"

    if type == INSTANCE_TYPE:  return "$(program.class_name_for outer).$name"

    if type == GLOBAL_TYPE or TOP_LEVEL_TYPE:
      if not holder_name: return name
      if name == "constructor":
        // An unnamed constructor.
        return holder_name;
      return "$holder_name.$name"

    unreachable

  stringify program/Program:
    prefix := prefix_string program
    return "$(%-50s prefix) $error_path:$position"

  short_stringify:
    return "$name $error_path:$position"

  stringify:
    return "$error_path:$position: method $name $outer"

class ClassInfo:
  id            / int
  super_id      / int?
  location_id   / int
  name          / string
  absolute_path / string
  error_path    / string
  position      / Position
  /**
  The direct fields of this class.
  Does not include the inherited fields.
  */
  fields      / List

  constructor .id .super_id .location_id .name .absolute_path .error_path .position .fields:

  stringify:
    return "$(%-30s name)  $absolute_path:$position"

class GlobalInfo:
  id          / int
  name        / string
  holder_id   / int?
  holder_name / string?

  constructor .id .name .holder_id .holder_name:

  stringify:
    if holder_name: return "$(holder_name).$name ($id)"
    return "$name ($id)"

class SelectorClass:
  super_location_id /int?
  selectors /List  // of selector names.

  constructor .super_location_id .selectors:

  has_super -> bool: return super_location_id != null

abstract class SourceSegment extends Segment:
  strings_ ::= ?
  content_ := null

  constructor byte_array begin end .strings_:
    super byte_array begin end
    set_offset_ SegmentHeader.SIZE

  content:
    if not content_: content_ = read_content_
    return content_

  read_position_ -> Position:
    return Position read_cardinal_ read_cardinal_

  read_string_ -> string:
    return strings_.content[read_cardinal_]

  abstract read_content_

// Abstract class for a segment that contain a list of elements.
abstract class ListSegment extends SourceSegment:
  count_ := 0

  constructor byte_array begin end strings:
    super byte_array begin end strings
    count_ = read_cardinal_

  abstract read_element_ index / int

  read_content_:
    return List count_: read_element_ it

  content -> List: return super

  stringify:
    return "#$count_, $byte_size bytes"


abstract class MapSegment extends SourceSegment:
  count_ := 0

  constructor byte_array begin end strings:
    super byte_array begin end strings
    count_ = read_cardinal_

  abstract read_element_ -> List  // A pair of key / value.

  read_content_:
    result := {:}
    count_.repeat:
      element := read_element_
      result[element[0]] = element[1]
    return result

  content -> Map: return super

  stringify -> string:
    return "#$count_, $byte_size bytes"

// List of all methods present in the program after tree shaking.
class MethodSegment extends MapSegment:
  constructor byte_array begin end strings:
    super byte_array begin end strings

  read_bytecode_positions_:
    return Map read_cardinal_
      : read_cardinal_
      : read_position_

  read_as_class_names_:
    return Map read_cardinal_
      : read_cardinal_
      : read_string_

  read_pubsub_entry_ -> PubsubInfo:
    bytecode_position := read_cardinal_
    target_dispatch_index := read_cardinal_
    has_topic := read_byte_ == 1
    topic := read_string_
    return PubsubInfo
      bytecode_position
      target_dispatch_index
      has_topic ? topic : null

  read_pubsub_info_ -> List:
    return List read_cardinal_: read_pubsub_entry_

  read_element_ -> List:
    id    := read_cardinal_
    bytecode_size := read_cardinal_
    type  := read_byte_
    has_outer := read_byte_ == 1
    outer := has_outer ? read_cardinal_ : null
    name  := read_string_
    holder_name /string? := read_string_
    if holder_name == "": holder_name = null
    absolute_path  := read_string_
    path  := read_string_
    position := read_position_
    bytecode_positions := read_bytecode_positions_
    as_class_names := read_as_class_names_
    pubsub_info := read_pubsub_info_
    info := MethodInfo id bytecode_size name type outer holder_name \
        absolute_path path position bytecode_positions as_class_names pubsub_info
    return [info.id, info]

  stringify -> string:
    return "method_table: $super"


// List of all classes present in the program after tree shaking.
class ClassSegment extends ListSegment:

  constructor byte_array begin end strings:
    super byte_array begin end strings

  read_element_ index:
    encoded_super := read_cardinal_
    super_id := encoded_super == 0 ? null : encoded_super - 1
    location_id := read_cardinal_
    name := read_string_
    absolute_path := read_string_
    error_path := read_string_
    position := read_position_
    fields := List read_cardinal_: read_string_
    return ClassInfo index super_id location_id name absolute_path error_path position fields

  stringify:
    return "class_table: $super"

class PrimitiveModuleInfo:
  name ::= ""
  primitives ::= []

  constructor .name .primitives:

  stringify:
    return "Primitive module $name"

// List of all primitive tables in the vm when generating the vm.
class PrimitiveSegment extends ListSegment:

  constructor byte_array begin end strings:
    super byte_array begin end strings

  read_element_ index:
    return PrimitiveModuleInfo
      read_string_
      List read_cardinal_: read_string_

  stringify:
    return "primitives: $super"

class SelectorNamesSegment extends MapSegment:
  constructor byte_array begin end strings:
    super byte_array begin end strings

  read_element_ -> List:
    offset := read_cardinal_
    name   := read_string_
    return [offset, name]

  stringify -> string:
    return "selector_names_table: $super"

class GlobalSegment extends ListSegment:
  constructor byte_array begin end strings:
    super byte_array begin end strings

  read_element_ global_id -> GlobalInfo:
    name := read_string_
    holder_name /string? := read_string_
    if holder_name == "": holder_name = null
    encoded_holder_id := read_cardinal_
    holder_id := encoded_holder_id == 0 ? null : encoded_holder_id - 1
    return GlobalInfo global_id name holder_id holder_name

  stringify -> string:
    return "globals: $super"

class SelectorsSegment extends MapSegment:
  constructor byte_array begin end strings:
    super byte_array begin end strings

  read_element_ -> List:  // A pair of key / value.
    location_id := read_cardinal_
    selector_class_entry := read_selector_class_
    return [location_id, selector_class_entry]

  read_selector_class_ -> SelectorClass:
    encoded_super_location_id := read_cardinal_
    super_location_id := encoded_super_location_id == 0
      ? null
      : encoded_super_location_id - 1
    selectors := List read_cardinal_: read_string_
    return SelectorClass super_location_id selectors

  stringify -> string:
    return "Selectors"

class PubsubInfo:
  bytecode_position /int ::= ?
  target_dispatch_index /int ::= ?
  topic /string? ::= ?

  constructor .bytecode_position .target_dispatch_index .topic:

class StringSegment extends ListSegment:

  constructor byte_array begin end:
    super byte_array begin end null

  read_element_ index:
    // Only place we read string content from debugging info.
    string_size := read_cardinal_
    pos_ += string_size
    return byte_array_.to_string pos_ - string_size pos_

  stringify:
    return "string: $super"
