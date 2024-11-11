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
import io show LITTLE-ENDIAN
import uuid show Uuid

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
  built-in-class-ids        / List ::= ?  // List of integers
  invoke-bytecode-offsets   / List ::= ?  // List of integers
  entry-point-indexes       / List ::= ?  // List of indexes into the dispatch_table
  class-tags                / List ::= ?  // List of class tags
  class-instance-sizes      / List ::= ?  // List of class instance sizes
  methods                   / List ::= ?  // List of ToitMethod. Extracted from the bytecodes.
  global-variables          / List ::= ?  // List of ToitObject
  class-check-ids           / List ::= ?  // Pairs of start/end id for class typechecks.
  interface-check-selectors / List ::= ?  // Selector offsets for interface typechecks.
  dispatch-table            / List ::= ?  // List of method ids
  literals                  / List ::= ?  // List of ToitObject
  heap-objects              / List ::= ?  // List of ToitObject
                                          // Contains all objects extracted from program heap.
  heap32                    / Heap ::= ?
  heap64                    / Heap ::= ?
  all-bytecodes             / ByteArray ::= ?
  global-max-stack-height   / int ::= ?

  // Debugging information.
  method-table_  / Map      ::= ?       // Map of MethodInfo

  // Note that the class_table can have more entries than the `class bits` list, as
  //   the debug-information could refer to classes that aren't instantiated, but for
  //   which instance methods are in the snapshot.
  class-table_    / List ::= []         // List of ClassInfo
  primitive-table / List ::= []         // List of PrimitiveModuleInfo
  selector-names_ / Map  ::= {:}        // Map from dispatch-offset to selector name.
  global-table    / List ::= ?          // List of GlobalInfo
  selectors_      / Map  ::= {:}        // Map from location-id to SelectorClass.

  static CLASS-TAG-SIZE_     ::= ToitHeapObject.CLASS-TAG-BIT-SIZE
  static CLASS-TAG-MASK_     ::= (1 << CLASS-TAG-SIZE_) - 1
  static CLASS-ID-SIZE_      ::= ToitHeapObject.CLASS-ID-BIT-SIZE
  static CLASS-ID-OFFSET_    ::= ToitHeapObject.CLASS-ID-OFFSET


  constructor snapshot/SnapshotBundle:
    snapshot.parse
    header                    = snapshot.program-snapshot.program-segment.header_
    roots                     = snapshot.program-snapshot.program-segment.roots_
    built-in-class-ids        = snapshot.program-snapshot.program-segment.built-in-class-ids_
    invoke-bytecode-offsets   = snapshot.program-snapshot.program-segment.invoke-bytecode-offsets_
    class-tags                = snapshot.program-snapshot.program-segment.class-bits_.map: it & CLASS-TAG-MASK_
    class-instance-sizes      = snapshot.program-snapshot.program-segment.class-bits_.map: it >> CLASS-ID-OFFSET_
    entry-point-indexes       = snapshot.program-snapshot.program-segment.entry-point-indexes_
    global-variables          = snapshot.program-snapshot.program-segment.global-variables_
    class-check-ids           = snapshot.program-snapshot.program-segment.class-check-ids_
    interface-check-selectors = snapshot.program-snapshot.program-segment.interface-check-selectors_
    dispatch-table            = snapshot.program-snapshot.program-segment.dispatch-table_
    literals                  = snapshot.program-snapshot.program-segment.literals_
    heap-objects              = snapshot.program-snapshot.program-segment.heap-objects_
    heap32                    = snapshot.program-snapshot.program-segment.heap32
    heap64                    = snapshot.program-snapshot.program-segment.heap64
    all-bytecodes             = snapshot.program-snapshot.program-segment.bytecodes_
    global-max-stack-height   = snapshot.program-snapshot.program-segment.global-max-stack-height_
    method-table_             = snapshot.source-map.method-segment.content
    class-table_              = snapshot.source-map.class-segment.content
    primitive-table           = snapshot.source-map.primitive-segment.content
    selector-names_           = snapshot.source-map.selector-names-segment.content
    global-table              = snapshot.source-map.global-segment.content
    selectors_                = snapshot.source-map.selectors-segment.content

    // Create the methods list.
    current-offset := 0
    methods = List method-table_.size:
      method-info := method-table_[current-offset]
      method := ToitMethod all-bytecodes current-offset method-info.bytecode-size
      current-offset += method.allocation-size
      method

  // Extract selector name from the dispatch offset used in invoke virtual byte codes.
  selector-from-dispatch-offset offset/int -> string:
    return selector-from-dispatch-offset offset --if-absent=:"Unknown D$offset"

  selector-from-dispatch-offset offset/int [--if-absent] -> string:
    return selector-names_.get offset --if-absent=if-absent

  method-info-for id/int -> MethodInfo:
    return method-info-for id: throw "Unknown method"

  method-info-for id/int [failure] -> MethodInfo:
    return method-table_.get id --if-absent=(: failure.call id)

  method-name-for id/int -> string:
    return (method-info-for id).name

  method-info-size -> int: return method-table_.size

  class-info-for id/int -> ClassInfo:
    return class-table_[id]

  class-info-for id/int [failure] -> ClassInfo:
    if not 0 <= id < class-table_.size: return failure.call id
    return class-table_[id]

  class-name-for id/int -> string:
    return (class-info-for id).name

  selector-class-for location-id/int -> SelectorClass:
    return selectors_[location-id]

  do --class-infos/True [block]:
    class-table_.do block

  do --method-infos/True [block]:
    method-table_.do --values block

  method-from-absolute-bci absolute-bci/int -> ToitMethod:
    if absolute-bci >= methods.last.absolute-entry-bci: return methods.last
    index := methods.index-of
        absolute-bci
        --binary-compare=: | a/ToitMethod b/int | a.absolute-entry-bci.compare-to b
        --if-absent=: | insertion-index |
          // $insertion_index is the place where absolute_bci would need to be
          //   inserted. As such, the previous index contains the method
          //   that contains the absolute_bci.
          insertion-index - 1
    assert: methods[index].absolute-entry-bci <= absolute-bci <= methods[index + 1].id;
    return methods[index]

  primitive-name module-index/int primitive-index/int -> string:
    module := primitive-table[module-index];
    return "$module.name::$module.primitives[primitive-index]"


class SnapshotBundle:
  static MAGIC-NAME        / string ::= "toit"
  static MAGIC-CONTENT     / string ::= "like a tiger"
  static SNAPSHOT-NAME     / string ::= "snapshot"
  static SOURCE-MAP-NAME   / string ::= "source-map"
  static UUID-NAME         / string ::= "uuid"
  static SDK-VERSION-NAME  / string ::= "sdk-version"

  bytes            / ByteArray
  file-name        / string?
  program-snapshot / ProgramSnapshot
  source-map       / SourceMap?
  uuid             / Uuid
  sdk-version      / string

  constructor.from-file name/string:
    return SnapshotBundle name (file.read-content name)

  constructor byte-array/ByteArray:
    return SnapshotBundle null byte-array

  constructor .file-name .bytes:
    if not is-bundle-content bytes: throw "Invalid snapshot bundle"
    program-snapshot-offsets := extract-ar-offsets_ bytes SNAPSHOT-NAME
    program-snapshot = ProgramSnapshot bytes program-snapshot-offsets.from program-snapshot-offsets.to
    source-map-offsets := extract-ar-offsets_ --silent bytes SOURCE-MAP-NAME
    source-map = source-map-offsets
        ? SourceMap bytes source-map-offsets.from source-map-offsets.to
        : null
    uuid-offsets := extract-ar-offsets_ bytes UUID-NAME
    uuid = uuid-offsets ? (Uuid bytes[uuid-offsets.from..uuid-offsets.to]) : Uuid.NIL
    sdk-version-offsets := extract-ar-offsets_ bytes SDK-VERSION-NAME
    sdk-version = sdk-version-offsets
        ? bytes[sdk-version-offsets.from..sdk-version-offsets.to].to-string-non-throwing
        : ""

  static is-bundle-content buffer/ByteArray -> bool:
    magic-file-offsets := extract-ar-offsets_ --silent buffer MAGIC-NAME
    if not magic-file-offsets: return false
    magic-content := buffer.copy  magic-file-offsets.from magic-file-offsets.to
    if magic-content.to-string != MAGIC-CONTENT: return false
    return true

  has-source-map -> bool:
    return source-map != null

  parse -> none:
    program-snapshot.parse

  decode -> Program:
    if not source-map: throw "No source map"
    return Program this

  stringify -> string:
    postfix := file-name ? " ($file-name)" : ""
    source-map-suffix := source-map ? " - $source-map\n" : ""
    return "snapshot: $bytes.size bytes$postfix\n - $program-snapshot\n$source-map-suffix"

  static extract-ar-offsets_ --silent/bool=false bytes/ByteArray name/string -> ArFileOffsets?:
    ar-reader := ArReader.from-bytes bytes
    offsets := ar-reader.find --offsets name
    if not offsets:
      if silent: return null
      throw "Invalid snapshot bundle"
    return offsets

class ProgramHeader:
  block-count32 /int
  block-count64 /int
  offheap-pointer-count /int
  offheap-int32-count /int
  offheap-byte-count /int
  back-table-length /int
  large-integer-id /int

  constructor
      .block-count32
      .block-count64
      .offheap-pointer-count
      .offheap-int32-count
      .offheap-byte-count
      .back-table-length
      .large-integer-id:

class ProgramSnapshot:
  program-segment / ProgramSegment ::= ?
  byte-array      / ByteArray      ::= ?
  from            / int            ::= ?
  to              / int            ::= ?

  constructor .byte-array/ByteArray .from/int .to/int:
    header := SegmentHeader byte-array from
    assert: header.content-size == to - from
    program-segment = ProgramSegment byte-array from to

  byte-size: return to - from

  parse -> none:
    program-segment.parse

  stringify -> string:
    return "$program-segment"

class SourceMap:
  method-segment    / MethodSegment    ::= ?
  class-segment     / ClassSegment     ::= ?
  primitive-segment / PrimitiveSegment ::= ?
  global-segment    / GlobalSegment    ::= ?
  selector-names-segment / SelectorNamesSegment ::= ?
  selectors-segment / SelectorsSegment ::= ?
  string-segment    / StringSegment    ::= ?

  constructor byte-array/ByteArray from/int to/int:
    pos := from
    // For typing reasons we first assign to the nullable locals,
    // and then only to the non-nullable fields.
    method-segment-local    / MethodSegment?    := null
    class-segment-local     / ClassSegment?     := null
    primitive-segment-local / PrimitiveSegment? := null
    global-segment-local    / GlobalSegment?    := null
    selector-names-segment-local / SelectorNamesSegment? := null
    selectors-segment-local / SelectorsSegment? := null
    string-segment-local    / StringSegment?    := null
    while pos < to:
      header := SegmentHeader byte-array pos
      // The string segment must be the first one.
      assert: string-segment-local != null or header.is-string-segment
      if header.is-string-segment:
        string-segment-local = StringSegment byte-array pos (pos + header.content-size)
      else if header.is-method-segment:
        method-segment-local = MethodSegment byte-array pos (pos + header.content-size) string-segment-local
      else if header.is-class-segment:
        class-segment-local = ClassSegment byte-array pos (pos + header.content-size) string-segment-local
      else if header.is-primitive-segment:
        primitive-segment-local = PrimitiveSegment byte-array pos (pos + header.content-size) string-segment-local
      else if header.is-global-names-segment:
        global-segment-local = GlobalSegment byte-array pos (pos + header.content-size) string-segment-local
      else if header.is-selector-names-segment:
        selector-names-segment-local = SelectorNamesSegment byte-array pos (pos + header.content-size) string-segment-local
      else if header.is-selectors-segment:
        selectors-segment-local = SelectorsSegment byte-array pos (pos + header.content-size) string-segment-local
      pos += header.content-size

    method-segment    = method-segment-local
    class-segment     = class-segment-local
    primitive-segment = primitive-segment-local
    global-segment    = global-segment-local
    selector-names-segment = selector-names-segment-local
    selectors-segment = selectors-segment-local
    string-segment    = string-segment-local

  stringify -> string:
    return "$method-segment\n - $class-segment\n - $primitive-segment\n - $selector-names-segment"

OBJECT-TAG          ::= 0
IN-TABLE-TAG        ::= 1
BACK-REFERENCE-TAG  ::= 2
POSITIVE-SMI-TAG    ::= 3
NEGATIVE-SMI-TAG    ::= 4

OBJECT-HEADER-WIDTH ::= 3
OBJECT-HEADER-TYPE-MASK ::= (1 << OBJECT-HEADER-WIDTH) - 1

class SegmentHeader:
  static SIZE ::= 8
  tag_ ::= 0
  content-size ::= 0

  constructor byte-array offset:
    tag_         = LITTLE-ENDIAN.uint32 byte-array offset
    content-size = LITTLE-ENDIAN.uint32 byte-array (offset + 4)

  is-program-snapshot:  return tag_ == 70177017
  is-object-snapshot:   return tag_ == 0x70177017
  is-string-segment:    return tag_ == 70177018
  is-method-segment:    return tag_ == 70177019
  is-class-segment:     return tag_ == 70177020
  is-primitive-segment: return tag_ == 70177021
  is-selector-names-segment: return tag_ == 70177022
  is-global-names-segment:   return tag_ == 70177023
  is-selectors-segment: return tag_ == 70177024

  stringify:
    return "$tag_:$content-size"

class Segment:
  byte-array_ ::= ?
  begin_ ::= 0
  end_ ::= 0
  pos_ := 0

  constructor .byte-array_ .begin_ .end_:
    set-offset_ 0

  byte-size:
    return end_ - begin_

  set-offset_ offset:
    pos_ = begin_ + offset

  read-uint16_:
    result := LITTLE-ENDIAN.uint16 byte-array_ pos_
    pos_ += 2
    return result

  read-uint32_:
    result := LITTLE-ENDIAN.uint32 byte-array_ pos_
    pos_ += 4
    return result

  read-int32_:
    result := LITTLE-ENDIAN.int32 byte-array_ pos_
    pos_ += 4
    return result

  read-float_:
    result := byte-array_.to-float --no-big-endian pos_
    pos_ += 8
    return result

  read-byte_:
    return byte-array_[pos_++]

  read-cardinal_:
    result := 0
    byte := read-byte_
    shift := 0
    while byte >= 128:
      result += (byte - 128) << shift
      shift += 7
      byte = read-byte_
    result += byte << shift
    return result

  read-list-int32_ -> List:
    size := read-int32_
    return List size: read-int32_

  read-list-uint16_ -> List:
    size := read-int32_
    return List size: read-uint16_

  read-list-uint8_ -> ByteArray:
    size := read-int32_
    result := ByteArray size
    result.replace 0 byte-array_ pos_ (pos_ + size)
    pos_ += size
    return result

TAG-SIZE ::= 1

class ToitObject:

abstract class ToitHeapObject extends ToitObject:
  static CLASS-TAG-BIT-SIZE/int ::= 4
  static CLASS-TAG-OFFSET/int ::= 0
  static CLASS-TAG-MASK/int ::= (1 << CLASS-TAG-BIT-SIZE) - 1

  static FINALIZER-BIT-SIZE/int ::= 1
  static FINALIZER-BIT-OFFSET/int ::= CLASS-TAG-OFFSET + CLASS-TAG-BIT-SIZE
  static FINALIZER-BIT-MASK/int ::= (1 << FINALIZER-BIT-SIZE) - 1

  static CLASS-ID-BIT-SIZE/int ::= 10
  static CLASS-ID-OFFSET/int ::= FINALIZER-BIT-OFFSET + FINALIZER-BIT-SIZE
  static CLASS-ID-MASK/int ::= (1 << CLASS-ID-BIT-SIZE) - 1

  header/int? := null
  hash-id_/int

  static HASH-COUNTER_ := 0

  constructor:
    hash-id_ = HASH-COUNTER_++

  class-id -> int:
    assert: header
    return (header >> CLASS-ID-OFFSET) & CLASS-ID-MASK

  class-tag -> int:
    assert: header
    return (header >> CLASS-TAG-OFFSET) & CLASS-TAG-MASK

  hash-code -> int: return hash-id_

  abstract read-from heap-segment/HeapSegment optional-length/int
  abstract store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none

  static HEADER-WORD-SIZE / int ::= 1  // The header (class id and class tag).

class ToitArray extends ToitHeapObject:
  static TAG ::= 0  // Must match TypeTag enum in objects.h.
  // Includes the length, but not the elements.
  static ARRAY-HEADER-WORD-SIZE ::= ToitHeapObject.HEADER-WORD-SIZE + 1
  content := []

  read-from heap-segment optional-length:
    content = List optional-length: heap-segment.read-object_

  store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none:
    words := ARRAY-HEADER-WORD-SIZE + optional-length
    heap32.store this words 0
    if heap64: heap64.store this words 0

class ToitByteArray extends ToitHeapObject:
  static SNAPSHOT-INTERNAL-SIZE-CUTOFF ::= (Heap.PAGE-WORD-SIZE-32 * 4) >> 2
  // Includes the length. But not the following bytes.
  static INTERNAL-WORD-SIZE ::= ToitHeapObject.HEADER-WORD-SIZE + 1
  // Length, address, tag.
  static EXTERNAL-WORD-SIZE ::= ToitHeapObject.HEADER-WORD-SIZE + 3
  static TAG ::= 5  // Must match TypeTag enum in objects.h.
  content /ByteArray := ByteArray 0

  read-from heap-segment optional-length:
    if optional-length > SNAPSHOT-INTERNAL-SIZE-CUTOFF:
      content = heap-segment.read-list-uint8_
    else:
      content = ByteArray optional-length: heap-segment.read-cardinal_

  store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none:
    word-size := ?
    extra-bytes := ?
    if optional-length > SNAPSHOT-INTERNAL-SIZE-CUTOFF:
      word-size = EXTERNAL-WORD-SIZE
      extra-bytes = 0
    else:
      word-size = INTERNAL-WORD-SIZE
      extra-bytes = optional-length
    heap32.store this word-size extra-bytes
    if heap64: heap64.store this word-size extra-bytes


class ToitMethod:
  static HEADER-SIZE ::= 4

  static METHOD ::= 0
  static FIELD-ACCESSOR ::= 1
  static LAMBDA ::= 2
  static BLOCK ::= 3

  id     ::= 0
  arity  ::= 0
  kind   ::= 0
  max-height ::= 0
  value  ::= 0
  bytecodes / ByteArray := ?

  constructor all-bytecodes/ByteArray at/int bytecode-size/int:
    id = at
    arity = all-bytecodes[at++]
    kind-height := all-bytecodes[at++]
    kind       = kind-height & 0x3
    max-height = (kind-height >> 2) * 4
    value = LITTLE-ENDIAN.int16 all-bytecodes at
    at += 2
    assert: at - id == HEADER-SIZE
    bytecodes = all-bytecodes.copy at (at + bytecode-size)

  is-normal-method -> bool: return kind == METHOD
  is-field-accessor -> bool: return kind == FIELD-ACCESSOR
  is-lambda -> bool: return kind == LAMBDA
  is-block -> bool: return kind == BLOCK

  allocation-size -> int:
    return HEADER-SIZE + bytecodes.size

  selector-offset:
    return value

  absolute-entry-bci -> int:
    return id + HEADER-SIZE

  bci-from-absolute-bci absolute-bci/int -> int:
    bci := absolute-bci - id - HEADER-SIZE
    // For method calls the return-bci is just after the call. If a method
    // is known not to return, then there might not be any bytecodes left and
    // the bci is equal to the bytecode size.
    assert: 0 <= bci <= bytecodes.size
    return bci

  absolute-bci-from-bci bci/int -> int:
    assert: 0 <= bci < bytecodes.size
    return bci + id + HEADER-SIZE

  // bytecode_string is static to support future byte code tracing.
  static bytecode-string method/ToitMethod bci index program/Program --show-positions/bool=true:
    opcode := method.bytecodes[bci]
    bytecode := BYTE-CODES[opcode]
    line := "[$(%03d opcode)] - $bytecode.description"
    format := bytecode.format
    if format == OP:
    else if format  == OP-BU:
      line += " $index"
    else if format == OP-SU:
      line += " $(method.uint16 bci + 1)"
    else if format == OP-BS:
      line += " S$index"
    else if format == OP-SS:
      line += " S$(method.uint16 bci + 1)"
    else if format == OP-BL:
      if index == 0:
        line += " true"
      else if index == 1:
        line += " false"
      else:
        line += " $program.literals[index]"
    else if format == OP-SL:
      line += " $program.literals[method.uint16 bci + 1]"
    else if format == OP-BC:
      line += " $(program.class-name-for index)"
    else if format == OP-SC:
      line += " $(program.class-name-for (method.uint16 bci + 1))"
    else if format == OP-BG:
      line += " G$index"
    else if format == OP-SG:
      line += " G$(method.uint16 bci + 1)"
    else if format == OP-BF:
      line += " T$(bci + index)"
    else if format == OP-SF:
      line += " T$(bci + (method.uint16 bci + 1))"
    else if format == OP-SB-SB:
      line += " T$(bci - (method.uint16 bci + 1))"
    else if format == OP-BCI:
      is-nullable := (index & 1) != 0
      class-index := index >> 1
      start-id := program.class-check-ids[class-index * 2]
      end-id   := program.class-check-ids[class-index * 2 + 1]
      start-name := program.class-name-for start-id
      line += " $start-name$(is-nullable ? "?" : "")($start-id - $end-id)"
    else if format == OP-SCI:
      index = method.uint16 bci + 1
      is-nullable := (index & 1) != 0
      class-index := index >> 1
      start-id := program.class-check-ids[class-index * 2]
      end-id   := program.class-check-ids[class-index * 2 + 1]
      start-name := program.class-name-for start-id
      line += " $start-name$(is-nullable ? "?" : "")($start-id - $end-id)"
    else if format == OP-BII:
      is-nullable := (index & 1) != 0
      selector-index := index >> 1
      selector-offset := program.interface-check-selectors[selector-index]
      selector-name := program.selector-from-dispatch-offset selector-offset
      line += " $selector-name$(is-nullable ? "?" : "")"
    else if format == OP-SII:
      index = method.uint16 bci + 1
      is-nullable := (index & 1) != 0
      selector-index := index >> 1
      selector-offset := program.interface-check-selectors[selector-index]
      selector-name := program.selector-from-dispatch-offset selector-offset
      line += " $selector-name$(is-nullable ? "?" : "")"
    else if format == OP-BLC:
      local := index >> 5
      class-index := index & 0x1F
      start-id := program.class-check-ids[class-index * 2]
      end-id   := program.class-check-ids[class-index * 2 + 1]
      start-name := program.class-name-for start-id
      line += " $local - $start-name($start-id - $end-id)"
    else if format == OP-SD:
      dispatch-index := method.uint16 bci + 1
      target := program.dispatch-table[dispatch-index]
      debug-info := program.method-info-for target
      line += " $(debug-info.short-stringify program --show-positions=show-positions)"
    else if format == OP-SO:
      offset := method.uint16 bci + 1
      line += " $(program.selector-from-dispatch-offset offset)"
    else if format == OP-WU:
      value := method.uint32 bci + 1
      if bytecode.name == "LOAD_METHOD":
        debug-info := program.method-info-for value
        line += " $(debug-info.short-stringify program --show-positions=show-positions)"
      else:
        line += " $value"
    else if format == OP-BS-BU:
      line += " S$index $(method.bytecodes[bci+2])"
    else if format == OP-BS-SO:
      offset := method.uint16 bci + 2
      line += " $(program.selector-from-dispatch-offset offset)"
    else if format == OP-BU-SO:
      offset := method.uint16 bci + 2
      line += " $(program.selector-from-dispatch-offset offset)"
    else if format == OP-BU-SU:
      if bytecode.name == "PRIMITIVE":
        primitive-index := method.uint16 bci + 2
        name := program.primitive-name index primitive-index
        line += " {$name}"
      else:
        line += " $index $(method.uint16 bci + 2)"
    else if format == OP-BU-WU:
      height := index
      target-absolute-bci := method.uint32 bci + 2
      target-method := program.method-from-absolute-bci target-absolute-bci
      target-bci := target-method.bci-from-absolute-bci target-absolute-bci
      target-method-info := program.method-info-for target-method.id: null
      target-name := target-method-info and (target-method-info.prefix-string program)
      line += " {$target-name:$target-bci}"
    else if format == OP-SS-SO:
      offset := method.uint16 bci + 3
      line += " $(program.selector-from-dispatch-offset offset)"
    else if format == OP-SU-SU:
      arity := method.uint16 bci + 1
      height := method.uint16 bci + 3
      line += " $arity $height"
    else if format == OP-SD-BS-BU:
      dispatch-index := method.uint16 bci + 1
      height := method.uint8 bci + 3
      arity := method.uint8 bci + 4
      target := program.dispatch-table[dispatch-index]
      debug-info := program.method-info-for target
      line += " $(debug-info.short-stringify program) S$height $arity"
    else:
      line += "UNKNOWN FORMAT"
    return line

  // Helper method to extract values from bytecode stream.
  uint8 offset: return LITTLE-ENDIAN.uint8 bytecodes offset

  // Helper method to extract values from bytecode stream.
  uint16 offset: return LITTLE-ENDIAN.uint16 bytecodes offset

  // Helper method to extract values from bytecode stream.
  uint32 offset: return LITTLE-ENDIAN.uint32 bytecodes offset

  do-call bci index program/Program [block]:
    opcode := bytecodes[bci]
    bytecode := BYTE-CODES[opcode]
    format := bytecode.format
    if format == OP-SD:
      target := program.dispatch-table[uint16 bci + 1]
      debug-info := program.method-info-for target
      block.call debug-info.name
    else if format == OP-SO:
      block.call
        program.selector-from-dispatch-offset
          uint16 bci + 1
    else if format == OP-BS-SO:
      block.call
        program.selector-from-dispatch-offset
          uint16 bci + 2
    else if format == OP-BU-SO:
      block.call
        program.selector-from-dispatch-offset
          uint16 bci + 2

  do-calls program [block]:
    effective := 0
    index := 0
    length := bytecodes.size
    while index < length:
      opcode := bytecodes[index]
      bc-length := BYTE-CODES[opcode].size
      if bc-length > 1:
        argument := bytecodes[index + 1]
        effective = (effective << 8) | argument;
      do-call index effective program block
      if opcode != 0: effective = 0;
      index += bc-length

  do-bytecodes [block]:
    index := 0
    length := bytecodes.size
    while index < length:
      opcode := bytecodes[index]
      block.call BYTE-CODES[opcode] index
      bc-length := BYTE-CODES[opcode].size
      index += bc-length

  output program/Program:
    output program null: null
    print ""

  output program/Program arguments/List? --show-positions/bool=true [block]:
    debug-info := program.method-info-for id
    prefix := show-positions ? "$id: " : ""
    print "$prefix$(debug-info.short-stringify program --show-positions=show-positions)"
    if arguments:
      arguments.size.repeat: | n |
        print "$prefix - argument $n: $arguments[n]"
    index := 0
    length := bytecodes.size
    while index < length:
      absolute-bci := absolute-bci-from-bci index
      line := "$(%3d index)"
      if show-positions: line += "/$(%4d absolute-bci) "
      opcode := bytecodes[index]
      bc-length := BYTE-CODES[opcode].size
      argument := 0;
      if bc-length > 1:
        argument = bytecodes[index + 1]
      line += bytecode-string this index argument program --show-positions=show-positions
      if extra := block.call absolute-bci: line += " // $extra"
      print line
      index += bc-length

  hash-code:
    return id

  operator == other:
    return other is ToitMethod and other.id == id

  stringify program/Program:
    debug-info := program.method-info-for id
    return debug-info.short-stringify

  stringify:
    return "Method $id"

// Bytecode formats
OP       ::=  1
OP-BU    ::=  2
OP-BS    ::=  3
OP-BL    ::=  4
OP-BC    ::=  5
OP-BG    ::=  6
OP-BF    ::=  7
OP-BCI   ::=  8
OP-BII   ::=  9
OP-BLC   ::= 10
OP-SU    ::= 11
OP-SF    ::= 12
OP-BS-BU ::= 13
OP-SD    ::= 14
OP-SO    ::= 15
OP-WU    ::= 16
OP-BS-SO ::= 17
OP-BU-SO ::= 18
OP-BU-SU ::= 19
OP-BU-WU ::= 20
OP-SD-BS-BU ::= 21
OP-SS    ::= 22
OP-SL    ::= 23
OP-SG    ::= 24
OP-SC    ::= 25
OP-SS-SO ::= 26
OP-SCI   ::= 27
OP-SII   ::= 28
OP-SB-SB ::= 29
OP-SU-SU ::= 30

class Bytecode:
  name        ::= ""
  size        ::= 0
  format      ::= 0
  description ::= ""

  constructor .name .size .format .description:

// TODO(Lau): Fix alignment.
BYTE-CODES ::= [
  Bytecode "LOAD_LOCAL"                 2 OP-BS "load local",
  Bytecode "LOAD_LOCAL_WIDE"            3 OP-SS "load local wide",
  Bytecode "POP_LOAD_LOCAL"             2 OP-BS "pop, load local",
  Bytecode "STORE_LOCAL"                2 OP-BS "store local",
  Bytecode "STORE_LOCAL_POP"            2 OP-BS "store local, pop",
  Bytecode "LOAD_OUTER"                 2 OP-BS "load outer",
  Bytecode "STORE_OUTER"                2 OP-BS "store outer",
  Bytecode "LOAD_FIELD"                 2 OP-BU "load field",
  Bytecode "LOAD_FIELD_WIDE"            3 OP-SU "load field wide",
  Bytecode "LOAD_FIELD_LOCAL"           2 OP-BU "load field local",
  Bytecode "POP_LOAD_FIELD_LOCAL"       2 OP-BU "pop, load field local",
  Bytecode "STORE_FIELD"                2 OP-BU "store field",
  Bytecode "STORE_FIELD_WIDE"           3 OP-SU "store field wide",
  Bytecode "STORE_FIELD_POP"            2 OP-BU "store field, pop",
  Bytecode "LOAD_LOCAL_0"               1 OP "load local 0",
  Bytecode "LOAD_LOCAL_1"               1 OP "load local 1",
  Bytecode "LOAD_LOCAL_2"               1 OP "load local 2",
  Bytecode "LOAD_LOCAL_3"               1 OP "load local 3",
  Bytecode "LOAD_LOCAL_4"               1 OP "load local 4",
  Bytecode "LOAD_LOCAL_5"               1 OP "load local 5",
  Bytecode "LOAD_LITERAL"               2 OP-BL "load literal",
  Bytecode "LOAD_LITERAL_WIDE"          3 OP-SL "load literal wide",
  Bytecode "LOAD_NULL"                  1 OP "load null",
  Bytecode "LOAD_SMI_0"                 1 OP "load smi 0",
  Bytecode "LOAD_SMIS_0"                2 OP-BU "load smis 0",
  Bytecode "LOAD_SMI_1"                 1 OP "load smi 1",
  Bytecode "LOAD_SMI_U8"                2 OP-BU "load smi",
  Bytecode "LOAD_SMI_U16"               3 OP-SU "load smi",
  Bytecode "LOAD_SMI_U32"               5 OP-WU "load smi",
  Bytecode "LOAD_METHOD"                5 OP-WU "load method",  // Has specialized stringification.
  Bytecode "LOAD_GLOBAL_VAR"            2 OP-BG "load global var",
  Bytecode "LOAD_GLOBAL_VAR_WIDE"       3 OP-SG "load global var wide",
  Bytecode "LOAD_GLOBAL_VAR_LAZY"       2 OP-BG "load global var lazy",
  Bytecode "LOAD_GLOBAL_VAR_LAZY_WIDE"  3 OP-SG "load global var lazy wide",
  Bytecode "LOAD_GLOBAL_VAR_DYNAMIC"    1 OP "load global var dynamic",
  Bytecode "STORE_GLOBAL_VAR"           2 OP-BG "store global var",
  Bytecode "STORE_GLOBAL_VAR_WIDE"      3 OP-SG "store global var wide",
  Bytecode "STORE_GLOBAL_VAR_DYNAMIC"   1 OP "store global var dynamic",
  Bytecode "LOAD_BLOCK"                 2 OP-BU "load block",
  Bytecode "LOAD_OUTER_BLOCK"           2 OP-BU "load outer block",
  Bytecode "POP"                        2 OP-BU "pop",
  Bytecode "POP_1"                      1 OP "pop 1",
  Bytecode "ALLOCATE"                   2 OP-BC "allocate instance",
  Bytecode "ALLOCATE_WIDE"              3 OP-SC "allocate instance wide",
  Bytecode "IS_CLASS"                   2 OP-BCI "is class",
  Bytecode "IS_CLASS_WIDE"              3 OP-SCI "is class wide",
  Bytecode "IS_INTERFACE"               2 OP-BII "is interface",
  Bytecode "IS_INTERFACE_WIDE"          3 OP-SII "is interface wide",
  Bytecode "AS_CLASS"                   2 OP-BCI "as class",
  Bytecode "AS_CLASS_WIDE"              3 OP-SCI "as class wide",
  Bytecode "AS_INTERFACE"               2 OP-BII "as interface",
  Bytecode "AS_INTERFACE_WIDE"          3 OP-SII "as interface wide",
  Bytecode "AS_LOCAL"                   2 OP-BLC "load local, as class, pop",
  Bytecode "INVOKE_STATIC"              3 OP-SD "invoke static",
  Bytecode "INVOKE_STATIC_TAIL"         5 OP-SD-BS-BU "invoke static tail",
  Bytecode "INVOKE_BLOCK"               2 OP-BS "invoke block",
  Bytecode "INVOKE_LAMBDA_TAIL"         2 OP-BF "invoke lambda tail",
  Bytecode "INVOKE_INITIALIZER_TAIL"    3 OP-BS-BU "invoke initializer tail",
  Bytecode "INVOKE_VIRTUAL"             4 OP-BS-SO "invoke virtual",
  Bytecode "INVOKE_VIRTUAL_WIDE"        5 OP-SS-SO "invoke virtual wide",
  Bytecode "INVOKE_VIRTUAL_GET"         3 OP-SO "invoke virtual get",
  Bytecode "INVOKE_VIRTUAL_SET"         3 OP-SO "invoke virtual set",
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
  Bytecode "INVOKE_SIZE"                3 OP-SO "invoke size",
  Bytecode "BRANCH"                     3 OP-SF "branch",
  Bytecode "BRANCH_IF_TRUE"             3 OP-SF "branch if true",
  Bytecode "BRANCH_IF_FALSE"            3 OP-SF "branch if false",
  Bytecode "BRANCH_BACK"                5 OP-SB-SB "branch back",
  Bytecode "BRANCH_BACK_IF_TRUE"        5 OP-SB-SB "branch back if true",
  Bytecode "BRANCH_BACK_IF_FALSE"       5 OP-SB-SB "branch back if false",
  Bytecode "PRIMITIVE"                  4 OP-BU-SU "invoke primitive",
  Bytecode "THROW"                      2 OP-BU "throw",
  Bytecode "RETURN"                     3 OP-BS-BU "return",
  Bytecode "RETURN_NULL"                3 OP-BS-BU "return null",
  Bytecode "NON_LOCAL_RETURN"           2 OP-BU "non-local return",
  Bytecode "NON_LOCAL_RETURN_WIDE"      4 OP-SU-SU "non-local return wide",
  Bytecode "NON_LOCAL_BRANCH"           6 OP-BU-WU "non-local branch",
  Bytecode "IDENTICAL"                  1 OP "identical",
  Bytecode "LINK"                       2 OP-BU "link try",
  Bytecode "UNLINK"                     2 OP-BU "unlink try",
  Bytecode "UNWIND"                     1 OP "unwind",
  Bytecode "HALT"                       2 OP-BU "halt",
  Bytecode "INTRINSIC_SMI_REPEAT"       1 OP "intrinsic smi repeat",
  Bytecode "INTRINSIC_ARRAY_DO"         1 OP "intrinsic array do",
  Bytecode "INTRINSIC_HASH_FIND"        1 OP "intrinsic hash find",
  Bytecode "INTRINSIC_HASH_DO"          1 OP "intrinsic hash do",
]


class ToitString extends ToitHeapObject:
  // in heap content:  [class:w][hash_code:h][length:h][content:byte*length][0][padding]
  // off heap content: [class:w][hash_code:h][-1:h]    [length:w][external_address:w]

  static SNAPSHOT-INTERNAL-SIZE-CUTOFF ::= (Heap.PAGE-WORD-SIZE-32 * 4) >> 2

  // hash+length.
  // It is then followed by the string and a terminating '\0'.
  static INTERNAL-WORD-SIZE ::= ToitHeapObject.HEADER-WORD-SIZE + 1
  // Internal + actual-length, address.
  static EXTERNAL-WORD-SIZE ::= INTERNAL-WORD-SIZE + 2

  static TAG ::= 1  // Must match TypeTag enum in objects.h.

  content/ByteArray? := null

  read-from heap-segment optional-length:
    if optional-length > SNAPSHOT-INTERNAL-SIZE-CUTOFF:
      null-terminated := heap-segment.read-list-uint8_
      content = null-terminated[..null-terminated.size - 1]
    else:
      content = ByteArray optional-length: heap-segment.read-byte_

  store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none:
    word-size := ?
    extra-bytes := ?
    if optional-length > SNAPSHOT-INTERNAL-SIZE-CUTOFF:
      word-size = EXTERNAL-WORD-SIZE
      extra-bytes = 0
    else:
      word-size = INTERNAL-WORD-SIZE
      // Content, and a terminating '\0'.
      extra-bytes = optional-length + 1
    heap32.store this word-size extra-bytes
    if heap64: heap64.store this word-size extra-bytes

  stringify:
    return content.to-string


class ToitOddball extends ToitHeapObject:
  static TAG ::= 3  // Must match TypeTag enum in objects.h.

  stringify:
    return "Oddball (true/false/null)"

  store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none:
    header-size := ToitHeapObject.HEADER-WORD-SIZE
    heap32.store this header-size 0
    if heap64: heap64.store this header-size 0

  read-from heap-segment optional-length:


class ToitInstance extends ToitHeapObject:
  static TAG ::= 2  // Must match TypeTag enum in objects.h.

  fields := []

  read-from heap-segment optional-length:
    field-count := heap-segment.read-cardinal_
    fields = List field-count: heap-segment.read-object_

  store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none:
    word-count := ToitHeapObject.HEADER-WORD-SIZE + optional-length
    heap32.store this word-count 0
    if heap64: heap64.store this word-count 0


class ToitFloat extends ToitHeapObject:
  static TAG ::= 4  // Must match TypeTag enum in objects.h.

  value := 0.0

  read-from heap-segment optional-length:
    value = heap-segment.read-float_

  store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none:
    word-count := ToitHeapObject.HEADER-WORD-SIZE
    extra-bytes := 8
    heap32.store this word-count extra-bytes
    if heap64: heap64.store this word-count extra-bytes

  stringify:
    return "$value"


class ToitInteger extends ToitHeapObject:
  value ::= 0

  constructor .value:

  stringify:
    return "$value"

  hash-code:
    return value

  operator == other:
    return other is ToitInteger and other.value == value


  static MIN-SMI32-VALUE ::= -(1 << (32 - (TAG-SIZE + 1)))
  static MAX-SMI32-VALUE ::= (1 << (32 - (TAG-SIZE + 1))) - 1
  static is-valid32 v:
    return MIN-SMI32-VALUE <= v <= MAX-SMI32-VALUE

  static MIN-SMI64-VALUE ::= -(1 << (64 - (TAG-SIZE + 1)))
  static MAX-SMI64-VALUE ::= (1 << (64 - (TAG-SIZE + 1))) - 1
  static is-valid64 v:
    return MIN-SMI64-VALUE <= v <= MAX-SMI64-VALUE

  store-in-heaps heap32/Heap heap64/Heap? optional-length/int -> none:
    word-count := ToitHeapObject.HEADER-WORD-SIZE
    extra-bytes := 8
    heap32.store this word-count extra-bytes
    if heap64: heap64.store this word-count extra-bytes

  read-from heap-segment optional-length: unreachable

/**
A simulated heap.
Contains a mapping from offset to object.
*/
class Heap:
  static PAGE-WORD-SIZE-32 / int ::= 1 << 10
  static PAGE-WORD-SIZE-64 / int ::= 1 << 12
  // Each block reserves 2 words for the `Block` object.
  static BLOCK-HEADER-WORD-SIZE / int ::= 2

  /// Word size in bytes.
  /// Must be either 4 or 8.
  word-size / int ::= ?

  /// Map from offset to Heap-object.
  offsets_ / Map ::= {:}

  current-byte-offset_ / int:= 0
  remaining-words-in-block_ / int := 0

  constructor .word-size:

  /// Stores the given $object in the heap.
  /// The object's size is given in $words and extra $bytes.
  ///
  /// The object might not be fully initialized yet (which is another reason
  ///   we want the $words and $bytes, instead of asking the object directly).
  store object/ToitHeapObject words/int bytes/int -> none:
    aligned-word-size := total-words_ words bytes
    if remaining-words-in-block_ < aligned-word-size:
      // Discard the rest of the block.
      allocate_ remaining-words-in-block_
      remaining-words-in-block_ = word-size == 4 ? PAGE-WORD-SIZE-32 : PAGE-WORD-SIZE-64
      allocate_ BLOCK-HEADER-WORD-SIZE
    object-offset := allocate_ aligned-word-size
    offsets_[object-offset] = object

  /// Returns the object at the given heap offset.
  object-at offset/int -> ToitHeapObject:
    return offsets_[offset]

  /** Computes the fully aligned size of an object with the given $words and extra $bytes. */
  total-words_ words bytes -> int:
    aligned-extra-bytes := (bytes + (word-size - 1) & ~(word-size - 1))
    return words + (aligned-extra-bytes / word-size)

  /// Updates the current offset and the remaining size in the block.
  /// Returns the old byte offset.
  allocate_ words / int -> int:
    assert: remaining-words-in-block_ >= words
    result := current-byte-offset_
    remaining-words-in-block_ -= words
    current-byte-offset_ += words * word-size
    return result

abstract class HeapSegment extends Segment:
  back-table_   / List ::= []
  // Collected for easier iteration.
  heap-objects_ / List ::= []

  heap32 / Heap ::= Heap 4
  heap64 / Heap ::= Heap 8

  constructor byte-array begin end:
    super byte-array begin end

  parsed_ := false
  parse-result := null

  parse [block]:
    if not parsed_:
      parse-result = block.call
      parsed_ = true
    return parse-result

  read-integer_ is-non-negative:
    value := read-cardinal_
    result-value := is-non-negative ? value : -value
    result := ToitInteger result-value
    if not ToitInteger.is-valid64 result-value:
      store-in-heap_ result 0
    else if not ToitInteger.is-valid32 result-value:
      store-in-heap_ --only32 result 0
    return result

  allocate-object_ tag -> ToitHeapObject:
    if tag == ToitArray.TAG:     return ToitArray
    if tag == ToitByteArray.TAG: return ToitByteArray
    if tag == ToitString.TAG:    return ToitString
    if tag == ToitOddball.TAG:   return ToitOddball
    if tag == ToitInstance.TAG:  return ToitInstance
    if tag == ToitFloat.TAG:     return ToitFloat
    throw "Unknown Toit object tag: $tag"

  read-object_ -> ToitObject:
    header := read-cardinal_
    type := header & OBJECT-HEADER-TYPE-MASK
    extra := header >> OBJECT-HEADER-WIDTH
    if type == NEGATIVE-SMI-TAG: return read-integer_ false
    if type == POSITIVE-SMI-TAG: return read-integer_ true
    if type == BACK-REFERENCE-TAG: return get-back-reference_ extra
    assert: (type == OBJECT-TAG) or (type == IN-TABLE-TAG)
    in-table := type == IN-TABLE-TAG
    optional-length := extra
    heap-tag := read-byte_
    result := allocate-object_ heap-tag
    store-in-heap_ result optional-length
    heap-objects_.add result
    if in-table: back-table_.add result
    result.header = (read-object_ as ToitInteger).value
    result.read-from this optional-length
    return result

  store-in-heap_ --only32/bool=false object/ToitHeapObject optional-length/int:
    object.store-in-heaps
        heap32
        only32 ? null : heap64
        optional-length

  get-back-reference_ index/int -> ToitObject: return back-table_[index]

  abstract get-program-heap-reference_ id -> ToitObject

class ProgramSegment extends HeapSegment:
  header_ /ProgramHeader?    := null
  roots_                     := []
  built-in-class-ids_        := []
  invoke-bytecode-offsets_   := []
  entry-point-indexes_       := []
  class-bits_                := []
  global-variables_          := []
  literals_                  := []
  class-check-ids_           := []
  interface-check-selectors_ := []
  dispatch-table_            := []
  bytecodes_                 := null
  global-max-stack-height_   := 0

  constructor byte-array begin end:
    super byte-array begin end

  parse -> none:
    super: read-program_

  parse-header_:
    encoded-normal-block-count := read-uint32_
    block-count32 := encoded-normal-block-count >> 16
    block-count64 := encoded-normal-block-count & 0xFFFF
    offheap-pointer-count := read-uint32_
    offheap-int32-count   := read-uint32_
    offheap-byte-count    := read-uint32_
    back-table-length     := read-uint32_
    large-integer-id      := read-uint32_
    header_ = ProgramHeader
        block-count32
        block-count64
        offheap-pointer-count
        offheap-int32-count
        offheap-byte-count
        back-table-length
        large-integer-id
    return back-table-length

  read-program_:
    set-offset_ SegmentHeader.SIZE
    back-table-length := parse-header_
    class-bits_                = read-list-uint16_
    global-variables_          = List read-cardinal_: read-object_
    literals_                  = List read-cardinal_: read-object_
    roots_                     = List read-cardinal_: read-object_
    built-in-class-ids_        = List read-cardinal_: read-object_
    invoke-bytecode-offsets_   = List read-cardinal_: read-cardinal_ - 1
    entry-point-indexes_       = List read-cardinal_: read-cardinal_
    class-check-ids_           = read-list-uint16_
    interface-check-selectors_ = read-list-uint16_
    dispatch-table_            = read-list-int32_
    bytecodes_                 = read-list-uint8_
    global-max-stack-height_   = read-cardinal_
    if back-table_.size != back-table-length:
      throw "Bad back-table size"

  get-program-heap-reference_ offset -> ToitObject:
    throw "Program heaps must not have program heap references"

  stringify:
    return "program: $byte-size bytes"


class Position:
  line/int ::= ?
  column/int ::= ?
  constructor .line .column:

  operator == other -> bool:
    return other is Position and line == other.line and column == other.column

  stringify:
    return "$line:$column"


class MethodInfo:
  id /int ::= ?
  bytecode-size /int ::= ?
  name /string ::= ?
  type /int ::= ?
  outer /int? ::= ?
  holder-name /string? ::= ?
  absolute-path /string ::= ?
  error-path /string ::= ?
  position /Position ::= ?
  bytecode-positions /Map ::= ?  // of bytecode to Position
  as-class-names /Map ::= ?      // of bytecode to strings

  static INSTANCE-TYPE      ::= 0
  static GLOBAL-TYPE        ::= 1
  static LAMBDA-TYPE        ::= 2
  static BLOCK-TYPE         ::= 3
  static TOP-LEVEL-TYPE     ::= 4

  absolute-entry-bci -> int:
    return id + ToitMethod.HEADER-SIZE

  short-stringify program/Program --show-positions/bool=true:
    prefix := prefix-string program
    if show-positions: return "$prefix $error-path:$position"
    normalized-path := error-path.replace --all "\\" "/"
    return "$prefix $normalized-path"

  position relative-bci/int -> Position:
    return bytecode-positions.get relative-bci --if-absent=: position

  as-class-name relative-bci/int -> string:
    return as-class-names.get relative-bci --if-absent=: "<unknown>"

  print program/Program:
    print (stringify program)

  constructor .id .bytecode-size .name .type .outer .holder-name .absolute-path .error-path
      .position .bytecode-positions .as-class-names:

  stacktrace-string program/Program:
    if type == BLOCK-TYPE or type == LAMBDA-TYPE:
      info := program.method-info-for outer
      code-info := program.method-info-for id
      return "$(info.stacktrace-string program).$(code-info.name)"

    return prefix-string program

  prefix-string program/Program:
    if type == BLOCK-TYPE:
      info := program.method-info-for outer
      return "[block] in $(info.prefix-string program)"

    if type == LAMBDA-TYPE:
      info := program.method-info-for outer
      return "[lambda] in $(info.prefix-string program)"

    if type == INSTANCE-TYPE:  return "$(program.class-name-for outer).$name"

    if type == GLOBAL-TYPE or TOP-LEVEL-TYPE:
      if not holder-name: return name
      if name == "constructor":
        // An unnamed constructor.
        return holder-name;
      return "$holder-name.$name"

    unreachable

  stringify program/Program:
    prefix := prefix-string program
    return "$(%-50s prefix) $error-path:$position"

  short-stringify:
    return "$name $error-path:$position"

  stringify:
    return "$error-path:$position: method $name $outer"

class ClassInfo:
  id            / int
  super-id      / int?
  location-id   / int
  name          / string
  absolute-path / string
  error-path    / string
  position      / Position
  /**
  The direct fields of this class.
  Does not include the inherited fields.
  */
  fields      / List

  constructor .id .super-id .location-id .name .absolute-path .error-path .position .fields:

  stringify:
    return "$(%-30s name)  $absolute-path:$position"

class GlobalInfo:
  id          / int
  name        / string
  holder-id   / int?
  holder-name / string?

  constructor .id .name .holder-id .holder-name:

  stringify:
    if holder-name: return "$(holder-name).$name ($id)"
    return "$name ($id)"

class SelectorClass:
  super-location-id /int?
  selectors /List  // of selector names.

  constructor .super-location-id .selectors:

  has-super -> bool: return super-location-id != null

abstract class SourceSegment extends Segment:
  strings_ ::= ?
  content_ := null

  constructor byte-array begin end .strings_:
    super byte-array begin end
    set-offset_ SegmentHeader.SIZE

  content:
    if not content_: content_ = read-content_
    return content_

  read-position_ -> Position:
    return Position read-cardinal_ read-cardinal_

  read-string_ -> string:
    return strings_.content[read-cardinal_]

  abstract read-content_

// Abstract class for a segment that contain a list of elements.
abstract class ListSegment extends SourceSegment:
  count_ := 0

  constructor byte-array begin end strings:
    super byte-array begin end strings
    count_ = read-cardinal_

  abstract read-element_ index / int

  read-content_:
    return List count_: read-element_ it

  content -> List: return super

  stringify:
    return "#$count_, $byte-size bytes"


abstract class MapSegment extends SourceSegment:
  count_ := 0

  constructor byte-array begin end strings:
    super byte-array begin end strings
    count_ = read-cardinal_

  abstract read-element_ -> List  // A pair of key / value.

  read-content_:
    result := {:}
    count_.repeat:
      element := read-element_
      result[element[0]] = element[1]
    return result

  content -> Map: return super

  stringify -> string:
    return "#$count_, $byte-size bytes"

// List of all methods present in the program after tree shaking.
class MethodSegment extends MapSegment:
  constructor byte-array begin end strings:
    super byte-array begin end strings

  read-bytecode-positions_:
    return Map read-cardinal_
      : read-cardinal_
      : read-position_

  read-as-class-names_:
    return Map read-cardinal_
      : read-cardinal_
      : read-string_

  read-element_ -> List:
    id    := read-cardinal_
    bytecode-size := read-cardinal_
    type  := read-byte_
    has-outer := read-byte_ == 1
    outer := has-outer ? read-cardinal_ : null
    name  := read-string_
    holder-name /string? := read-string_
    if holder-name == "": holder-name = null
    absolute-path  := read-string_
    path  := read-string_
    position := read-position_
    bytecode-positions := read-bytecode-positions_
    as-class-names := read-as-class-names_
    info := MethodInfo id bytecode-size name type outer holder-name \
        absolute-path path position bytecode-positions as-class-names
    return [info.id, info]

  stringify -> string:
    return "method_table: $super"


// List of all classes present in the program after tree shaking.
class ClassSegment extends ListSegment:

  constructor byte-array begin end strings:
    super byte-array begin end strings

  read-element_ index:
    encoded-super := read-cardinal_
    super-id := encoded-super == 0 ? null : encoded-super - 1
    location-id := read-cardinal_
    name := read-string_
    absolute-path := read-string_
    error-path := read-string_
    position := read-position_
    fields := List read-cardinal_: read-string_
    return ClassInfo index super-id location-id name absolute-path error-path position fields

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

  constructor byte-array begin end strings:
    super byte-array begin end strings

  read-element_ index:
    return PrimitiveModuleInfo
      read-string_
      List read-cardinal_: read-string_

  stringify:
    return "primitives: $super"

class SelectorNamesSegment extends MapSegment:
  constructor byte-array begin end strings:
    super byte-array begin end strings

  read-element_ -> List:
    offset := read-cardinal_
    name   := read-string_
    return [offset, name]

  stringify -> string:
    return "selector_names_table: $super"

class GlobalSegment extends ListSegment:
  constructor byte-array begin end strings:
    super byte-array begin end strings

  read-element_ global-id -> GlobalInfo:
    name := read-string_
    holder-name /string? := read-string_
    if holder-name == "": holder-name = null
    encoded-holder-id := read-cardinal_
    holder-id := encoded-holder-id == 0 ? null : encoded-holder-id - 1
    return GlobalInfo global-id name holder-id holder-name

  stringify -> string:
    return "globals: $super"

class SelectorsSegment extends MapSegment:
  constructor byte-array begin end strings:
    super byte-array begin end strings

  read-element_ -> List:  // A pair of key / value.
    location-id := read-cardinal_
    selector-class-entry := read-selector-class_
    return [location-id, selector-class-entry]

  read-selector-class_ -> SelectorClass:
    encoded-super-location-id := read-cardinal_
    super-location-id := encoded-super-location-id == 0
      ? null
      : encoded-super-location-id - 1
    selectors := List read-cardinal_: read-string_
    return SelectorClass super-location-id selectors

  stringify -> string:
    return "Selectors"

class StringSegment extends ListSegment:

  constructor byte-array begin end:
    super byte-array begin end null

  read-element_ index:
    // Only place we read string content from debugging info.
    string-size := read-cardinal_
    pos_ += string-size
    return byte-array_.to-string pos_ - string-size pos_

  stringify:
    return "string: $super"
