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

import crypto show *
import .snapshot
import encoding.ubjson as ubjson
import encoding.base64 as base64

// Mirror object to mimic object on a remote system.
// Used for stack traces, debugging etc.

abstract class Mirror:
  json ::= ?
  program/Program ::= ?

  constructor .json .program/Program:

  abstract stringify -> string

  terminal_stringify: return stringify

class Stack extends Mirror:
  static tag ::= 'S'
  frames ::= []

  constructor json program/Program [on_error]:
    frames = json[1].map: decode_json_ it program on_error
    super json program

  stringify -> string:
    if frames.is_empty: return "the empty stack"
    result := []
    previous_index := -1
    frames.do:
      if it.index != previous_index + 1: result.add "..."
      if it.is_user_boundary: return result.join "\n"
      previous_index = it.index
      result.add it.stringify
    return result.join "\n"


class Frame extends Mirror:
  static tag ::= 'F'
  index ::= 0
  id ::= 0
  absolute_bci ::= 0
  bci ::= 0

  stacktrace_method_string/string ::= ?
  method/ToitMethod ::= ?
  method_info/MethodInfo ::= ?
  position/Position ::= ?

  constructor json program/Program [on_error]:
    index = json[1]
    absolute_bci = json[2]
    method = program.method_from_absolute_bci absolute_bci
    id = method.id
    method_info = program.method_info_for id: null
    bci = method_info and method.bci_from_absolute_bci absolute_bci
    position = method_info and method_info.position bci
    stacktrace_method_string = method_info.stacktrace_string program
    super json program

  is_user_boundary -> bool:
    return (method_info != null) and stacktrace_method_string.starts_with "__entry__"

  stringify -> string:
    prefix := "$(%3d index): " + stacktrace_method_string
    if not (method_info and position): return "$(%-30s prefix) method id=$id, bci=$bci"
    return "$(%-30s prefix) $method_info.error_path:$position.line:$position.column"


class Instance extends Mirror:
  static tag ::= 'I'
  class_id/int ::= ?

  constructor json program/Program [on_error]:
    class_id = json[1]
    super json program

  is_vowel char/int -> bool:
    "aeiouAEIOU".do: if it == char: return true
    return false

  stringify -> string:
    class_name := program.class_name_for class_id
    return "$((is_vowel class_name[0]) ? "an" : "a") $class_name"


class Array extends Mirror:
  static tag ::= 'A'
  size ::= 0
  content ::= []

  constructor json program/Program [on_error]:
    size = json[1]
    content = json[2].map: decode_json_ it program on_error
    super json program

  stringify -> string:
    if size == content.size: return "$content"
    elements := content.join ", "
    return "List #$(size)[$elements, ...]"

// We use MList to avoid name collision with List.
class MList extends Mirror:
  static tag ::= 'L'
  size ::= 0
  content ::= []

  constructor json program/Program [on_error]:
    size = json[1]
    content = json[2].map: decode_json_ it program on_error
    super json program

  stringify -> string:
    if size == content.size: return "List $content"
    elements := content.join ", "
    return "List #$(size)[$elements, ...]"


class Error extends Mirror:
  static tag ::= 'E'

  type ::= ?
  message ::= ?
  trace := ?

  constructor json program/Program [on_error]:
    type = decode_json_ json[1] program on_error
    message = decode_json_ json[2] program on_error
    trace = decode_json_ json[3] program on_error
    super json program

  // Whether the class has a selector.
  // Looks also in super classes.
  class_has_selector_ class_id/int selector/string -> bool:
    class_info := program.class_info_for class_id
    location_id := class_info.location_id
    while true:
      selector_class := program.selector_class_for location_id
      selectors := selector_class.selectors
      // A linear search through the selectors.
      if selectors.contains selector: return true
      if not selector_class.has_super: return false
      location_id = selector_class.super_location_id

  lookup_failure_stringify -> string:
    // message is an array [selector string or a method id, receiver] that can identify a selector.
    if message is not Array: return "Lookup failed message:$message.\n$trace"
    selector_or_method_id := message.content[0]
    receiver_class_id := message.content[1]
    receiver := message.content[2]

    selector := null
    if selector_or_method_id is num:
      selector = program.selector_from_dispatch_offset selector_or_method_id
          --if_absent= :
            return """
              Lookup failed when calling selector with offset \
              $selector_or_method_id on $(typed_expression_string_ receiver).
              $trace"""
    else:
      selector = selector_or_method_id
    has_selector := class_has_selector_ receiver_class_id selector
    class_name := class_name_for_ receiver receiver_class_id
    if has_selector:
      return "Argument mismatch for '$class_name.$selector'.\n$trace"
    return "Class '$class_name' does not have any method '$selector'.\n$trace"

  as_check_failure_stringify -> string:
    // message is an array [expression, id]
    if message is not Array: return "As check failed message:$message.\n$trace"
    expression := message.content[0]
    id := message.content[1]
    class_name := id
    if id is string:
      class_name = id
    else:
      assert: id is int
      method := program.method_from_absolute_bci id
      relative_bci := method.bci_from_absolute_bci id
      method_info := program.method_info_for method.id
      class_name = method_info.as_class_name relative_bci
    return "As check failed: $(typed_expression_string_ expression) is not a $class_name.\n$trace"

  allocation_failed_stringify -> string:
    if message is not int:
      return "Allocation failed:$message.\n$trace"
    id := message
    class_info := program.class_info_for id:
      // Bad class id.
      return "Allocation failed:$message.\n$trace"
    class_name := class_info.name
    return "Allocation failed when trying to allocate an instance of $class_name\n$trace"

  initialization_in_progress_stringify -> string:
    if message is not int or not 0 <= message < program.global_table.size:
      return "Initialization of variable in progress: $message.\n$trace"
    global_id := message
    global_info := program.global_table[global_id]
    name := global_info.name
    kind := "global"
    if global_info.holder_name:
      name = "$(global_info.holder_name).$name"
      kind = "static field"
    return "Initialization of $kind '$name' in progress.\n$trace"

  uninitialized_global_stringify -> string:
    if message is not int or not 0 <= message < program.global_table.size:
      return "Trying to access uninitialized variable: $message.\n$trace"
    global_id := message
    global_info := program.global_table[global_id]
    name := global_info.name
    kind := "global"
    if global_info.holder_name:
      name = "$(global_info.holder_name).$name"
      kind = "static field"
    return "Trying to access uninitialized $kind '$name'.\n$trace"

  code_invocation_stringify -> string:
    if message is not Array or
        message.content.size != 4 or
        message.content[0] is not bool or
        message.content[1] is not int or
        message.content[2] is not int or
        message.content[3] is not int:
      return "Called block or lambda with too few arguments: $message\n$trace"
    is_block := message.content[0]
    expected := message.content[1]
    provided := message.content[2]
    absolute_bci := message.content[3]
    if is_block:
      // Remove the implicit block argument.
      expected--
      provided--
    method := program.method_from_absolute_bci absolute_bci
    method_info := program.method_info_for method.id
    name := method_info.stacktrace_string program
    return """
      Called $(is_block ? "block" : "lambda") with too few arguments.
      Got: $provided Expected: $expected.
      Target:
           $(%-25s name) $method_info.error_path:$method_info.position

      $trace"""

  stringify -> string:
    if type == "LOOKUP_FAILED": return lookup_failure_stringify
    if type == "AS_CHECK_FAILED": return as_check_failure_stringify
    if type == "ALLOCATION_FAILED": return allocation_failed_stringify
    if type == "INITIALIZATION_IN_PROGRESS": return initialization_in_progress_stringify
    if type == "UNINITIALIZED_GLOBAL": return uninitialized_global_stringify
    if type == "CODE_INVOCATION_FAILED": return code_invocation_stringify
    if message is string and message.size == 0: return "$type error.\n$trace"
    return "$type error. \n$message\n$trace"

  typed_expression_string_ expr:
    if expr is Instance: return expr.stringify
    if expr is MList: return expr.stringify
    if expr is Array: return expr.stringify
    if expr is string: return "a string (\"$expr\")"
    if expr is int: return "an int ($expr)"
    if expr is float: return "a float ($expr)"
    if expr is bool: return "a bool ($expr)"
    return expr.stringify

  class_name_for_ expr class_id:
    if expr is MList: return "List"
    if expr is Array: return "Array_"
    if expr is string: return "string"
    if expr is int: return "int"
    if expr is float: return "float"
    if expr is bool: return "bool"
    return program.class_name_for class_id

class Record:
  method ::= ?
  count  ::= ?

  constructor .method .count:

  stringify program total/int -> string:
    percentage ::= (count * 100).to_float/total
    return "$(%5.1f percentage)% $(%-20s method.stringify program)"

class Profile extends Mirror:
  static tag ::= 'P'

  title ::= "Toit application"
  entries ::= []
  cutoff ::= 0
  total ::= 0

  constructor json program/Program [on_error]:
    pos := 4
    title = decode_json_ json[1] program on_error
    cutoff = decode_json_ json[2] program on_error
    total = decode_json_ json[3] program on_error
    ((json.size - 4) / 2).repeat:
      entries.add
        Record
          program.method_info_for json[pos++]
          json[pos++]
    entries.sort --in_place: | a b | b.count - a.count
    super json program

  table:
    result := entries.map: it.stringify program total
    return result.join "\n"

  stringify -> string:
    return "Profile of $title ($total ticks, cutoff $(cutoff.to_float/10)%):\n$table"

class HistogramEntry:
  class_name /string
  count /int
  size /int

  constructor .class_name .count .size:

  stringify -> string:
    k := size < 1024 ? "       " : "$(%6d size >> 10)k"
    c := count == 0 ? "       " : "$(%7d count)"
    return "  │ $c │ $k $(%4d size & 0x3ff) │ $(%-45s class_name)│"

class Histogram extends Mirror:
  static tag ::= 'O'  // For Objects.

  marker_ /string
  entries /List ::= []

  constructor json program/Program [on_error]:
    assert:   json[0] == tag
    marker_ = json[1]
    first_entry := 2

    for i := first_entry; i < json.size; i += 3:
      class_name := program.class_name_for json[i]
      entries.add
          HistogramEntry class_name json[i + 1] json[i + 2]
    entries.sort --in_place: | a b | b.size - a.size
    super json program

  stringify -> string:
    marker := marker_ == "" ? "" : " for $marker_"
    total := HistogramEntry "Total" 0
        entries.reduce --initial=0: | a b | a + b.size
    return "Objects$marker:\n"
        + "  ┌─────────┬──────────────┬──────────────────────────────────────────────┐\n"
        + "  │   Count │        Bytes │ Class                                        │\n"
        + "  ├─────────┼──────────────┼──────────────────────────────────────────────┤\n"
        + (entries.join "\n") +                                                      "\n"
        + "  ╞═════════╪══════════════╪══════════════════════════════════════════════╡\n"
        + total.stringify +                                                          "\n"
        + "  └─────────┴──────────────┴──────────────────────────────────────────────┘"

class CoreDump extends Mirror:
  static tag ::= 'c'
  core_dump ::= ?

  constructor json program [on_error]:
    core_dump = json[1]
    super json program

  stringify -> string:
    output := "#    ************ ESP32 core dump file received.            **************\n"
    output += "#    ************ Decode by running the following commands: **************\n"
    output += "echo "
    output += base64.encode core_dump
    output += " | base64 --decode | zcat > /tmp/core.dump\n"
    output += "./third_party/esp-idf/components/espcoredump/espcoredump.py info_corefile -t raw -c /tmp/core.dump ./esp/toit/build/toit.elf"
    return output

class MallocReport extends Mirror:
  static tag ::= 'M'

  uses_list /List := []        // List of byte arrays, each entry is a bitmap.
  fullnesses_list /List := []  // List of byte arrays, each entry is a percentage fullness.
  base_addresses /List := []   // List of base adddresses.
  granularity /int

  static TERMINAL_SET_BACKGROUND_ ::= "\x1b[48;5;"
  static TERMINAL_SET_FOREGROUND_ ::= "\x1b[38;5;"
  static TERMINAL_RESET_COLORS_   ::= "\x1b[0m"
  static TERMINAL_WHITE_ ::= 231
  static TERMINAL_DARK_GREY_ ::= 232
  static TERMINAL_LIGHT_GREY_ ::= 255
  static TERMINAL_TOIT_HEAP_COLOR_ ::= 174  // Orange-ish.

  static MEMORY_PAGE_MALLOC_MANAGED_ ::= 1 << 0

  /**
  Bitmap mask for $uses_list.
  Indicates the page was allocated for the Toit heap.
  */
  static MEMORY_PAGE_TOIT_            ::= 1 << 1

  /**
  Bitmap mask for $uses_list.
  Indicates the page contains at least one allocation for external (large)
  Toit strings and byte arrays.
  */
  static MEMORY_PAGE_EXTERNAL_        ::= 1 << 2

  /**
  Bitmap mask for $uses_list.
  Indicates the page contains at least one allocation for TLS and other
  cryptographic uses.
  */
  static MEMORY_PAGE_TLS_             ::= 1 << 3

  /**
  Bitmap mask for $uses_list.
  Indicates the page contains at least one allocation for network buffers.
  */
  static MEMORY_PAGE_BUFFERS_         ::= 1 << 4

  /**
  Bitmap mask for $uses_list.
  Indicates the page contains at least one miscellaneous or unknown allocation.
  */
  static MEMORY_PAGE_MISC_            ::= 1 << 5

  /**
  Bitmap mask for $uses_list.
  Indicates that this page and the next page are part of a large multi-page
  allocation.
  */
  static MEMORY_PAGE_MERGE_WITH_NEXT_ ::= 1 << 6

  constructor json program [on_error]:
    for i := 1; i + 2 < json.size; i += 3:
      uses_list.add       json[i + 0]
      fullnesses_list.add json[i + 1]
      base_addresses.add  json[i + 2]
    granularity = json[json.size - 1]
    super json program

  stringify -> string:
    result := []
    key_ result --terminal=false
    for i := 0; i < uses_list.size; i++:
      uses := uses_list[i]
      fullnesses := fullnesses_list[i]
      base := base_addresses[i]
      for j := 0; j < uses.size; j++:
        if uses[j] != 0 or fullnesses[j] != 0:
          result.add "0x$(%08x base + j * granularity): $(%3d fullnesses[j])% $(usage_letters_ uses[j] fullnesses[j])"
        if uses[j] & MEMORY_PAGE_MERGE_WITH_NEXT_ == 0:
          result.add "--------------------------------------------------------"
    return result.join "\n"

  key_ result/List --terminal/bool -> none:
    k := granularity >> 10
    scale := ""
    for i := 232; i <= 255; i++: scale += "$TERMINAL_SET_BACKGROUND_$(i)m "
    scale += TERMINAL_RESET_COLORS_
    result.add   "┌────────────────────────────────────────────────────────────────────────┐"
    if terminal:
      result.add "│$(%2d k)k pages.  All pages are $(%2d k)k, even the ones that are shown wider       │"
      result.add "│ because they have many different allocations in them.                  │"
    else:
      result.add "│Each line is a $(%2d k)k page.                                                      │"
    result.add   "│   X  = External strings/bytearrays.        B  = Network buffers.       │"
    result.add   "│   W  = TLS/crypto.                         M  = Misc. allocations.     │"
    result.add   "│   🐱 = Toit managed heap.                  -- = Free page.             │"
    if terminal:
      result.add "│        Fully allocated $scale Completely free page.  │"
    result.add   "└────────────────────────────────────────────────────────────────────────┘"

  usage_letters_ use/int fullness/int -> string:
    symbols := ""
    if use & MEMORY_PAGE_TOIT_ != 0: symbols += "🐱"
    if use & MEMORY_PAGE_BUFFERS_ != 0: symbols = "B"
    if use & MEMORY_PAGE_EXTERNAL_ != 0: symbols = "X"
    if use & MEMORY_PAGE_TLS_ != 0: symbols = "W"
    if use & MEMORY_PAGE_MISC_ != 0: symbols = "M"
    if fullness == 0:
      symbols = "--"
    while symbols.size < 2:
      symbols += " "
    return symbols

  terminal_stringify -> string:
    result := []
    key_ result --terminal=true
    for i := 0; i < uses_list.size; i++:
      uses := uses_list[i]
      fullnesses := fullnesses_list[i]
      base := base_addresses[i]
      lowest := uses.size
      highest := 0
      for j := 0; j < uses.size; j++:
        if uses[j] != 0 or fullnesses[j] != 0:
          lowest = min lowest j
          highest = max highest j
      if lowest > highest: continue
      result.add "0x$(%08x base + lowest * granularity)-0x$(%08x base + (highest + 1) * granularity)"
      generate_line result uses fullnesses "┌"  "──┬"  "───"  "──┐" false
      generate_line result uses fullnesses "│"    "│"    " "    "│" true
      generate_line result uses fullnesses "└"  "──┴"  "───"  "──┘" false
    return result.join "\n"

  generate_line result/List uses/ByteArray fullnesses/ByteArray open/string allocation_end/string allocation_continue/string end/string is_data_line/bool -> none:
    line := []
    for i := 0; i < uses.size; i++:
      use := uses[i]
      if use == 0 and fullnesses[i] == 0: continue
      symbols := ""
      if use & MEMORY_PAGE_TOIT_ != 0: symbols = "🐱"
      if use & MEMORY_PAGE_BUFFERS_ != 0: symbols = "B"
      if use & MEMORY_PAGE_EXTERNAL_ != 0: symbols += "X"
      if use & MEMORY_PAGE_TLS_ != 0: symbols += "W"  // For WWW.
      if use & MEMORY_PAGE_MISC_ != 0: symbols += "M"  // For WWW.
      previous_was_unmanaged := i == 0 or (uses[i - 1] == 0 and fullnesses[i - 1] == 0)
      if previous_was_unmanaged:
        line.add open
      fullness := fullnesses[i]
      if fullness == 0:
        symbols = "--"
      while symbols.size < 2:
        symbols += " "
      if is_data_line:
        white_text := fullness > 50  // Percent.
        background_color := TERMINAL_LIGHT_GREY_ - (24 * fullness) / 100
        background_color = max background_color TERMINAL_DARK_GREY_
        if fullness == 0:
          background_color = TERMINAL_WHITE_
        else if use & MEMORY_PAGE_TOIT_ != 0:
          background_color = TERMINAL_TOIT_HEAP_COLOR_

        line.add "$TERMINAL_SET_BACKGROUND_$(background_color)m"
               + "$TERMINAL_SET_FOREGROUND_$(white_text ? TERMINAL_WHITE_ : TERMINAL_DARK_GREY_)m"
               + symbols + TERMINAL_RESET_COLORS_
      next_is_unmanaged := i == uses.size - 1 or (uses[i + 1] == 0 and fullnesses[i + 1] == 0)
      line_drawing := ?
      if next_is_unmanaged:
        line_drawing = end
      else if use & MEMORY_PAGE_MERGE_WITH_NEXT_ != 0:
        line_drawing = allocation_continue
      else:
        line_drawing = allocation_end
      if symbols.size > 2 and not is_data_line and symbols != "🐱":
        // Pad the line drawings on non-data lines to match the width of the
        // data.
        first_character := line_drawing[0..utf_8_bytes line_drawing[0]]
        line_drawing = (first_character * (symbols.size - 2)) + line_drawing
      line.add line_drawing
    result.add
        "  " + (line.join "")

class HeapReport extends Mirror:
  static tag ::= 'H'
  reason := ""
  pages ::= []

  constructor json program [on_error]:
    reason = json[1]
    pages = json[2].map: decode_json_ it program on_error
    pages.sort --in_place: | a b | a.address.compare_to b.address
    super json program

  stringify -> string:
    if pages.is_empty: return "$reason: empty heap"
    output := []
    output.add "$reason\n"
    pages.do:
      output.add it.stringify
    return (output.join "") + (BlackWhiteBlockOutputter_).key

  terminal_stringify -> string:
    if pages.is_empty: return "$reason: empty heap"
    output := []
    output.add "$reason\n"
    pages.do:
      output.add it.terminal_stringify
    return (output.join "") + (ColorBlockOutputter_).key

class HeapPage extends Mirror:
  static tag ::= 'p'  // Lower case 'p'.
  // Some sort of number giving the address of the start of the page.
  address ::= 0
  map ::= ?

  // Map is a byte array where each byte specifies a size and use of an
  // allocation on the page.  Allocation sizes are multiples of 8 bytes.
  // Byte format is as follows:
  // 1xxx xxxx      // Next byte's allocation size is extended by x * 32 bytes (gives up to 4k, which can cover a whole page).
  // 00xx yyyy      // 8, 16, 24 or 32 byte allocation of type yyyy.
  // 01xx yyyy      // 8 'overhead' bytes followed by 8, 16, 24 or 32 byte allocation of type yyyy
  //
  // This covers small allocations with 1 byte and large allocations with 2
  // bytes.  Worst case byte array is 256 long for a 4k page covered in 256
  // 8-byte allocations with 8 bytes of header between them.
  //
  // Known allocation types.
  //   ? 0 - misc
  //   A 1 - External byte array
  //   B 2 - Bignum
  //   S 3 - External string
  //   T 4 - Toit heap
  //   U 5 - Unused (spare) Toit heap
  //   F 6 - free or heap overhead (header)
  //   W 7 - LwIP
  //   H 8 - Malloc heap overhead

  static GRANULARITY_ ::= 8
  static HEADER_ ::= 8
  static PAGE_HEADER_ ::= 24
  static PAGE_ ::= 4096

  constructor json program [on_error]:
    address = json[1]
    map = json[2]
    super json program

  // Calls the block with arguments offset size use-character last_flag
  do [block]:
    offset := 0
    for i := 0; i < map.size; i++:
      extra := 0
      byte := map[i]
      while byte & 0b1000_0000 != 0:
        extra += (byte & 0b111_1111) * 4 * GRANULARITY_
        byte = map[++i]
      if byte & 0b0100_0000 != 0:
        block.call offset HEADER_ 'H' false
        offset += HEADER_
      repetitions := extra + (((byte >> 4) & 0b11) + 1) * GRANULARITY_
      use := byte & 0b1111
      usage_char := "?ABSTUFWH       "[use]
      block.call offset repetitions usage_char (offset + repetitions == PAGE_)
      offset += repetitions
    if offset < PAGE_:
      block.call offset (PAGE_ - offset) ' ' true

  stringify -> string:
    return print_ false

  terminal_stringify -> string:
    return print_ true

  print_ color:
    allocations := 0
    largest_free := 0
    unused := 0
    do: | offset size usage_char last_flag |
      if usage_char != 'F' and usage_char != 'H' and usage_char != ' ': allocations++
      if usage_char == 'F':
        if size > largest_free: largest_free = size
        unused += size
    ram_type := 0x4008_0000 <= address < 0x400A_0000 ? "  (IRAM)" : ""
    result := "    0x$(%08x address): $(unused * 100 / 4096)% free, largest space $largest_free bytes, allocations: $allocations$ram_type\n"
    blocks := color ? ColorBlockOutputter_ : BlackWhiteBlockOutputter_
    do: | offset size usage_char last_flag |
      (size / GRANULARITY_).repeat: blocks.add usage_char (it == size / GRANULARITY_ - 1 and last_flag)
    return result + blocks.buffer

DESCRIPTIONS_ ::= {
  '?': "Misc",
  'A': "External byte array",
  'B': "Bignum (crypto)",
  'S': "External string",
  'T': "Toit GCed heap",
  //'U': "Unused (spare) Toit GCed heap",  // Not currently in use.
  'F': "Free",
  'W': "LwIP",
  'H': "Malloc heap bookkeeping",
  ' ': "Not part of the heap",
}

abstract class BlockOutputter_:
  atoms := 0
  abstract add usage_char last_flag
  abstract buffer

class CharacterBlockOutputter_ extends BlockOutputter_:
  buffer := ""

  add usage_char last_flag:
    buffer += "$(%c usage_char)"
    atoms++
    if atoms & 0x7f == 0: buffer += "\n"

abstract class UnicodeBlockOutputter_ extends BlockOutputter_:
  previous_usage := null
  buffer := "     $("▁" * 64)\n    ▕"

  increment_atoms last_flag reset [block]:
    atoms++
    if atoms & 0x7f == 0:
      buffer += last_flag ?  "$reset▏\n     $("▔" * 64)\n" : "$reset▏\n    ▕"
      block.call

  abstract key

class BlackWhiteBlockOutputter_ extends UnicodeBlockOutputter_:
  key:
    result := ""
    DESCRIPTIONS_.do: | letter description |
      letter_string := letter == 'F' ? "█" : "$(%c letter)"
      result += "    $(description.pad 30) $letter_string\n"
    return result

  add usage_char last_flag:
    if atoms & 1 == 0:
      previous_usage = usage_char
    else:
      atom_was_free := previous_usage == 'F' or previous_usage == 'H'
      new_atom_is_free := usage_char == 'F' or usage_char == 'H'
      if not atom_was_free:
        if not new_atom_is_free:
          buffer += "$(%c usage_char)"
        else:
          buffer += "▐"
      else:
        if not new_atom_is_free:
          buffer += "▌"
        else:
          buffer += "█"
    increment_atoms last_flag "": null

class ColorBlockOutputter_ extends UnicodeBlockOutputter_:
  background := -1
  foreground := -1

  // Escape sequences for 256 color terminals.
  static BG ::= "\u001b[48;5;"
  static FG ::= "\u001b[38;5;"

  // See 256-color scheme at http://www.lihaoyi.com/post/BuildyourownCommandLinewithANSIescapecodes.html#256-colors
  colors ::= {
    '?': 240,  // Dark grey, misc allocated.
    'A': 48,   // External byte array.
    'B': 111,   // Bignum.
    'S': 190,  // External string.
    'T': 214,   // Toit heap.
    'U': 112,  // Unused (spare) Toit heap.
    'F': 44,   // Cyan, free memory.
    'W': 170,  // Purple, LwIP
    'H': 248,  // Heap overhead/headers.
    ' ': 15    // White, outside the heap.
  }

  key:
    result := ""
    DESCRIPTIONS_.do: | letter description |
      result += "    $BG$colors[letter]m $(description.pad 30) $(%c letter) $reset\n"
    return result

  reset ::= "\u001b[0m"

  add usage_char last_flag:
    if atoms & 1 == 0:
      previous_usage = usage_char
    else:
      new_background := colors[previous_usage]
      new_foreground := colors[usage_char]
      if new_background == new_foreground:
        if background != new_background:
          background = new_background
          buffer += "$BG$(background)m"
      if background == new_background and background == new_foreground:
        if foreground != 239:  // Dark grey
          foreground = 239
          buffer += "$FG$(foreground)m"
        buffer += "$(%c usage_char)"
      else:
        sequence := ""
        if background != new_background:
          sequence += "$BG$(new_background)m"
        if foreground != new_foreground:
          sequence += "$FG$(new_foreground)m"
        sequence += "▐"
        buffer += sequence
        foreground = new_foreground
        background = new_background

    increment_atoms last_flag reset:
      foreground = -1
      background = -1

decode byte_array program [on_error]:
  assert: byte_array is ByteArray and byte_array[0] == '['
  json := null
  error ::= catch: json = ubjson.decode byte_array
  if error:
    on_error.call error
    unreachable  // on_error callback shouldn't continue decoding.

  // First decode the header without using the program.
  if json is not List: return on_error.call "Expecting a list when decoding a structure"
  if json.size != 5: return on_error.call "Expecting five element list"
  if json.first != 'X': return on_error.call "Expecting Message"
  sdk_version  ::= json[1]
  sdk_model  ::= json[2]
  program_uuid ::= json[3]
  // Then decode the payload.
  return decode_json_ json[4] program on_error

decode_json_ json program/Program [on_error]:
  // First recognize basic types.
  if json is num: return json
  if json is string: return json
  if json is ByteArray: return json
  if json is bool: return json
  if json == null: return null
  // Then decode a real list as a system encoded data structure.
  assert: not json is ByteArray // Note: a ByteArray is also a List.
  assert: json is List
  if json.size == 0: return on_error.call "Expecting a non empty list"
  tag := json.first
  if      tag == Array.tag:        return Array        json program on_error
  else if tag == MList.tag:        return MList        json program on_error
  else if tag == Stack.tag:        return Stack        json program on_error
  else if tag == Frame.tag:        return Frame        json program on_error
  else if tag == Error.tag:        return Error        json program on_error
  else if tag == Instance.tag:     return Instance     json program on_error
  else if tag == Profile.tag:      return Profile      json program on_error
  else if tag == Histogram.tag:    return Histogram    json program on_error
  else if tag == HeapReport.tag:   return HeapReport   json program on_error
  else if tag == HeapPage.tag:     return HeapPage     json program on_error
  else if tag == CoreDump.tag:     return CoreDump     json program on_error
  else if tag == MallocReport.tag: return MallocReport json program on_error
  return on_error.call "Unknown tag: $tag"
