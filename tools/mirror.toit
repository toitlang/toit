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
import uuid

// Mirror object to mimic object on a remote system.
// Used for stack traces, debugging etc.

abstract class Mirror:
  json ::= ?
  program/Program? ::= ?

  constructor .json .program:

  terminal-stringify: return stringify

class Stack extends Mirror:
  static tag ::= 'S'
  frames ::= []

  constructor json program/Program? [--if-error]:
    if not program: throw "Stack trace can't be decoded without a snapshot"
    frames = json[1].map: decode-json_ it program --if-error=if-error
    super json program

  stringify -> string:
    if frames.is-empty: return "the empty stack"
    result := []
    previous-index := -1
    frames.do:
      if it.index != previous-index + 1: result.add "..."
      if it.is-user-boundary: return result.join "\n"
      previous-index = it.index
      result.add it.stringify
    return result.join "\n"


class Frame extends Mirror:
  static tag ::= 'F'
  index ::= 0
  id ::= 0
  absolute-bci ::= 0
  bci ::= 0

  stacktrace-method-string/string ::= ?
  method/ToitMethod ::= ?
  method-info/MethodInfo ::= ?
  position/Position ::= ?

  constructor json program/Program [--if-error]:
    index = json[1]
    absolute-bci = json[2]
    method = program.method-from-absolute-bci absolute-bci
    id = method.id
    method-info = program.method-info-for id: null
    bci = method-info and method.bci-from-absolute-bci absolute-bci
    position = method-info and method-info.position bci
    stacktrace-method-string = method-info.stacktrace-string program
    super json program

  is-user-boundary -> bool:
    return (method-info != null) and stacktrace-method-string.starts-with "__entry__"

  stringify -> string:
    prefix := "$(%3d index): " + stacktrace-method-string
    if not (method-info and position): return "$(%-30s prefix) method id=$id, bci=$bci"
    return "$(%-30s prefix) $method-info.error-path:$position.line:$position.column"


class Instance extends Mirror:
  static tag ::= 'I'
  class-id/int ::= ?

  constructor json program/Program? [--if-error]:
    class-id = json[1]
    super json program

  is-vowel char/int -> bool:
    "aeiouAEIOU".do: if it == char: return true
    return false

  stringify -> string:
    if not program: return "instance of class $class-id"
    class-name := program.class-name-for class-id
    return "$((is-vowel class-name[0]) ? "an" : "a") $class-name"


class Array extends Mirror:
  static tag ::= 'A'
  size ::= 0
  content ::= []

  constructor json program/Program? [--if-error]:
    size = json[1]
    content = json[2].map: decode-json_ it program --if-error=if-error
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

  constructor json program/Program? [--if-error]:
    size = json[1]
    content = json[2].map: decode-json_ it program --if-error=if-error
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

  constructor json program/Program? [--if-error]:
    type = decode-json_ json[1] program --if-error=if-error
    message = decode-json_ json[2] program --if-error=if-error
    if program:
      trace = decode-json_ json[3] program --if-error=if-error
    else:
      trace = null
    super json program

  // Whether the class has a selector.
  // Looks also in super classes.
  class-has-selector_ class-id/int selector/string -> bool:
    class-info := program.class-info-for class-id
    location-id := class-info.location-id
    while true:
      selector-class := program.selector-class-for location-id
      selectors := selector-class.selectors
      // A linear search through the selectors.
      if selectors.contains selector: return true
      if not selector-class.has-super: return false
      location-id = selector-class.super-location-id

  lookup-failure-stringify -> string:
    // message is an array [selector string or a method id, receiver] that can identify a selector.
    if message is not Array or not program:
      trace-suffix := trace ? "\n$trace" : ""
      return "Lookup failed message:$message.$trace-suffix"
    selector-or-method-id := message.content[0]
    receiver-class-id := message.content[1]
    receiver := message.content[2]

    selector := null
    if selector-or-method-id is num:
      selector = program.selector-from-dispatch-offset selector-or-method-id
          --if-absent= :
            return """
              Lookup failed when calling selector with offset \
              $selector-or-method-id on $(typed-expression-string_ receiver).
              $trace"""
    else:
      selector = selector-or-method-id
    has-selector := class-has-selector_ receiver-class-id selector
    class-name := class-name-for_ receiver receiver-class-id
    if has-selector:
      return "Argument mismatch for '$class-name.$selector'.\n$trace"
    return "Class '$class-name' does not have any method '$selector'.\n$trace"

  as-check-failure-stringify -> string:
    // message is an array [expression, id]
    if message is not Array or not program:
      trace-suffix := trace ? "\n$trace" : ""
      return "As check failed message:$message.$trace-suffix"
    expression := message.content[0]
    id := message.content[1]
    class-name := id
    if id is string:
      class-name = id
    else:
      assert: id is int
      method := program.method-from-absolute-bci id
      relative-bci := method.bci-from-absolute-bci id
      method-info := program.method-info-for method.id
      class-name = method-info.as-class-name relative-bci
    return "As check failed: $(typed-expression-string_ expression) is not a $class-name.\n$trace"

  serialization-failed-stringify -> string:
    // message is an integer, the failing class-id.
    if message is not int or not program:
      trace-suffix := trace ? "\n$trace" : ""
      return "Serialization failed: Cannot encode instance.$trace-suffix"
    class-id := message
    class-name := program.class-name-for class-id
    return "Serialization failed: Cannot encode instance of $class-name.\n$trace"

  allocation-failed-stringify -> string:
    if message is not int or not program:
      return "Allocation failed:$message.\n$trace"
    id := message
    class-info := program.class-info-for id:
      // Bad class id.
      return "Allocation failed:$message.\n$trace"
    class-name := class-info.name
    return "Allocation failed when trying to allocate an instance of $class-name\n$trace"

  initialization-in-progress-stringify -> string:
    if message is not int or not program or not 0 <= message < program.global-table.size:
      trace-suffix := trace ? "\n$trace" : ""
      return "Initialization of variable in progress: $message.$trace-suffix"
    global-id := message
    global-info := program.global-table[global-id]
    name := global-info.name
    kind := "global"
    if global-info.holder-name:
      name = "$(global-info.holder-name).$name"
      kind = "static field"
    return "Initialization of $kind '$name' in progress.\n$trace"

  uninitialized-global-stringify -> string:
    if message is not int or not program or not 0 <= message < program.global-table.size:
      trace-suffix := trace ? "\n$trace" : ""
      return "Trying to access uninitialized variable: $message.$trace-suffix"
    global-id := message
    global-info := program.global-table[global-id]
    name := global-info.name
    kind := "global"
    if global-info.holder-name:
      name = "$(global-info.holder-name).$name"
      kind = "static field"
    return "Trying to access uninitialized $kind '$name'.\n$trace"

  code-invocation-stringify -> string:
    if message is not Array or
        not program or
        message.content.size != 4 or
        message.content[0] is not bool or
        message.content[1] is not int or
        message.content[2] is not int or
        message.content[3] is not int:
      trace-suffix := trace ? "\n$trace" : ""
      return "Called block or lambda with too few arguments: $message$trace-suffix"
    is-block := message.content[0]
    expected := message.content[1]
    provided := message.content[2]
    absolute-bci := message.content[3]
    if is-block:
      // Remove the implicit block argument.
      expected--
      provided--
    method := program.method-from-absolute-bci absolute-bci
    method-info := program.method-info-for method.id
    name := method-info.stacktrace-string program
    return """
      Called $(is-block ? "block" : "lambda") with too few arguments.
      Got: $provided Expected: $expected.
      Target:
           $(%-25s name) $method-info.error-path:$method-info.position

      $trace"""

  stringify -> string:
    if type == "LOOKUP_FAILED": return lookup-failure-stringify
    if type == "AS_CHECK_FAILED": return as-check-failure-stringify
    if type == "SERIALIZATION_FAILED": return serialization-failed-stringify
    if type == "ALLOCATION_FAILED": return allocation-failed-stringify
    if type == "INITIALIZATION_IN_PROGRESS": return initialization-in-progress-stringify
    if type == "UNINITIALIZED_GLOBAL": return uninitialized-global-stringify
    if type == "CODE_INVOCATION_FAILED": return code-invocation-stringify
    if message is string and message.size == 0: return "$type error.\n$trace"
    trace-suffix := trace ? "\n$trace" : ""
    return "$type error. \n$message$trace-suffix"

  typed-expression-string_ expr:
    if expr is Instance: return expr.stringify
    if expr is MList: return expr.stringify
    if expr is Array: return expr.stringify
    if expr is string: return "a string (\"$expr\")"
    if expr is int: return "an int ($expr)"
    if expr is float: return "a float ($expr)"
    if expr is bool: return "a bool ($expr)"
    return expr.stringify

  class-name-for_ expr class-id:
    if expr is MList: return "List"
    if expr is Array: return "Array_"
    if expr is string: return "string"
    if expr is int: return "int"
    if expr is float: return "float"
    if expr is bool: return "bool"
    return program.class-name-for class-id

class Record:
  method ::= ?
  count  ::= ?

  constructor .method .count:

  stringify program total/int -> string:
    percentage ::= (count * 100).to-float/total
    return "$(%5.1f percentage)% $(%-20s method.stringify program)"

class Profile extends Mirror:
  static tag ::= 'P'

  title ::= "Toit application"
  entries ::= []
  cutoff ::= 0
  total ::= 0

  constructor json program/Program? [--if-error]:
    if not program: throw "Profile can't be decoded without a snapshot"
    pos := 4
    title = decode-json_ json[1] program --if-error=if-error
    cutoff = decode-json_ json[2] program --if-error=if-error
    total = decode-json_ json[3] program --if-error=if-error
    ((json.size - 4) / 2).repeat:
      entries.add
        Record
          program.method-info-for json[pos++]
          json[pos++]
    entries.sort --in-place: | a b | b.count - a.count
    super json program

  table:
    result := entries.map: it.stringify program total
    return result.join "\n"

  stringify -> string:
    return "Profile of $title ($total ticks, cutoff $(cutoff.to-float/10)%):\n$table"

class HistogramEntry:
  class-name /string
  count /int
  size /int

  constructor .class-name .count .size:

  stringify -> string:
    k := size < 1024 ? "       " : "$(%6d size >> 10)k"
    c := count == 0 ? "       " : "$(%7d count)"
    return "  │ $c │ $k $(%4d size & 0x3ff) │ $(%-45s class-name)│"

class Histogram extends Mirror:
  static tag ::= 'O'  // For Objects.

  marker_ /string
  entries /List ::= []

  constructor json program/Program? [--if-error]:
    if not program: throw "Histogram can't be decoded without a snapshot"
    assert:   json[0] == tag
    marker_ = json[1]
    first-entry := 2

    for i := first-entry; i < json.size; i += 3:
      class-name := program.class-name-for json[i]
      entries.add
          HistogramEntry class-name json[i + 1] json[i + 2]
    entries.sort --in-place: | a b | b.size - a.size
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
  core-dump ::= ?

  constructor json program [--if-error]:
    core-dump = json[1]
    super json program

  stringify -> string:
    output := "#    ************ ESP32 core dump file received.            **************\n"
    output += "#    ************ Decode by running the following commands: **************\n"
    output += "echo "
    output += base64.encode core-dump
    output += " | base64 --decode | zcat > /tmp/core.dump\n"
    output += "./third_party/esp-idf/components/espcoredump/espcoredump.py info_corefile -t raw -c /tmp/core.dump ./esp/toit/build/toit.elf"
    return output

class MallocReport extends Mirror:
  static tag ::= 'M'

  uses-list /List := []        // List of byte arrays, each entry is a bitmap.
  fullnesses-list /List := []  // List of byte arrays, each entry is a percentage fullness.
  base-addresses /List := []   // List of base adddresses.
  granularity /int

  static TERMINAL-SET-BACKGROUND_ ::= "\x1b[48;5;"
  static TERMINAL-SET-FOREGROUND_ ::= "\x1b[38;5;"
  static TERMINAL-RESET-COLORS_   ::= "\x1b[0m"
  static TERMINAL-WHITE_ ::= 231
  static TERMINAL-DARK-GREY_ ::= 232
  static TERMINAL-LIGHT-GREY_ ::= 255
  static TERMINAL-TOIT-HEAP-COLOR_ ::= 174  // Orange-ish.

  static MEMORY-PAGE-MALLOC-MANAGED_ ::= 1 << 0

  /**
  Bitmap mask for $uses-list.
  Indicates the page was allocated for the Toit heap.
  */
  static MEMORY-PAGE-TOIT_            ::= 1 << 1

  /**
  Bitmap mask for $uses-list.
  Indicates the page contains at least one allocation for external (large)
  Toit strings and byte arrays.
  */
  static MEMORY-PAGE-EXTERNAL_        ::= 1 << 2

  /**
  Bitmap mask for $uses-list.
  Indicates the page contains at least one allocation for TLS and other
  cryptographic uses.
  */
  static MEMORY-PAGE-TLS_             ::= 1 << 3

  /**
  Bitmap mask for $uses-list.
  Indicates the page contains at least one allocation for network buffers.
  */
  static MEMORY-PAGE-BUFFERS_         ::= 1 << 4

  /**
  Bitmap mask for $uses-list.
  Indicates the page contains at least one miscellaneous or unknown allocation.
  */
  static MEMORY-PAGE-MISC_            ::= 1 << 5

  /**
  Bitmap mask for $uses-list.
  Indicates that this page and the next page are part of a large multi-page
  allocation.
  */
  static MEMORY-PAGE-MERGE-WITH-NEXT_ ::= 1 << 6

  constructor json program [--if-error]:
    for i := 1; i + 2 < json.size; i += 3:
      uses-list.add       json[i + 0]
      fullnesses-list.add json[i + 1]
      base-addresses.add  json[i + 2]
    granularity = json[json.size - 1]
    super json program

  stringify -> string:
    result := []
    key_ result --terminal=false
    for i := 0; i < uses-list.size; i++:
      uses := uses-list[i]
      fullnesses := fullnesses-list[i]
      base := base-addresses[i]
      for j := 0; j < uses.size; j++:
        if uses[j] != 0 or fullnesses[j] != 0:
          result.add "0x$(%08x base + j * granularity): $(%3d fullnesses[j])% $(plain-usage-description_ uses[j] fullnesses[j])"
        if uses[j] & MEMORY-PAGE-MERGE-WITH-NEXT_ == 0:
          separator := "--------------------------------------------------------"
          if result[result.size - 1] != separator: result.add separator
    return result.join "\n"

  key_ result/List --terminal/bool -> none:
    k := granularity >> 10
    scale := ""
    for i := 232; i <= 255; i++: scale += "$TERMINAL-SET-BACKGROUND_$(i)m "
    scale += TERMINAL-RESET-COLORS_
    result.add   "┌────────────────────────────────────────────────────────────────────────┐"
    if terminal:
      result.add "│$(%2d k)k pages.  All pages are $(%2d k)k, even the ones that are shown wider       │"
      result.add "│ because they have many different allocations in them.                  │"
    else:
      result.add "│Each line is a $(%2d k)k page.                                                │"
    if terminal:
      result.add "│   X  = External strings/bytearrays.        B  = Network buffers.       │"
      result.add "│   W  = TLS/crypto.                         M  = Misc. allocations.     │"
      result.add "│   To = Toit managed heap.                  -- = Free page.             │"
      result.add "│        Fully allocated $scale Completely free page.  │"
    result.add   "└────────────────────────────────────────────────────────────────────────┘"

  // Only used for plain ASCII mode, not for terminal graphics mode.
  plain-usage-description_ use/int fullness/int -> string:
    if fullness == 0: return "(Free)"
    symbols := []
    if use & MEMORY-PAGE-TOIT_ != 0: symbols.add "Toit"
    if use & MEMORY-PAGE-BUFFERS_ != 0: symbols.add "Network Buffers"
    if use & MEMORY-PAGE-EXTERNAL_ != 0: symbols.add "External strings/bytearrays"
    if use & MEMORY-PAGE-TLS_ != 0: symbols.add "TLS/Crypto"
    if use & MEMORY-PAGE-MISC_ != 0: symbols.add "Misc"
    return symbols.join ", "

  terminal-stringify -> string:
    result := []
    key_ result --terminal=true
    for i := 0; i < uses-list.size; i++:
      uses := uses-list[i]
      fullnesses := fullnesses-list[i]
      base := base-addresses[i]
      lowest := uses.size
      highest := 0
      for j := 0; j < uses.size; j++:
        if uses[j] != 0 or fullnesses[j] != 0:
          lowest = min lowest j
          highest = max highest j
      if lowest > highest: continue
      result.add "0x$(%08x base + lowest * granularity)-0x$(%08x base + (highest + 1) * granularity)"
      generate-line result uses fullnesses "┌"  "──┬"  "───"  "──┐" false
      generate-line result uses fullnesses "│"    "│"    " "    "│" true
      generate-line result uses fullnesses "└"  "──┴"  "───"  "──┘" false
    return result.join "\n"

  generate-line result/List uses/ByteArray fullnesses/ByteArray open/string allocation-end/string allocation-continue/string end/string is-data-line/bool -> none:
    line := []
    for i := 0; i < uses.size; i++:
      use := uses[i]
      if use == 0 and fullnesses[i] == 0: continue
      symbols := ""
      if use & MEMORY-PAGE-TOIT_ != 0: symbols = "To"
      if use & MEMORY-PAGE-BUFFERS_ != 0: symbols = "B"
      if use & MEMORY-PAGE-EXTERNAL_ != 0: symbols += "X"
      if use & MEMORY-PAGE-TLS_ != 0: symbols += "W"  // For WWW.
      if use & MEMORY-PAGE-MISC_ != 0: symbols += "M"  // For WWW.
      previous-was-unmanaged := i == 0 or (uses[i - 1] == 0 and fullnesses[i - 1] == 0)
      if previous-was-unmanaged:
        line.add open
      fullness := fullnesses[i]
      if fullness == 0:
        symbols = "--"
      while symbols.size < 2:
        symbols += " "
      if is-data-line:
        white-text := fullness > 50  // Percent.
        background-color := TERMINAL-LIGHT-GREY_ - (24 * fullness) / 100
        background-color = max background-color TERMINAL-DARK-GREY_
        if fullness == 0:
          background-color = TERMINAL-WHITE_
        else if use & MEMORY-PAGE-TOIT_ != 0:
          background-color = TERMINAL-TOIT-HEAP-COLOR_

        line.add "$TERMINAL-SET-BACKGROUND_$(background-color)m"
               + "$TERMINAL-SET-FOREGROUND_$(white-text ? TERMINAL-WHITE_ : TERMINAL-DARK-GREY_)m"
               + symbols + TERMINAL-RESET-COLORS_
      next-is-unmanaged := i == uses.size - 1 or (uses[i + 1] == 0 and fullnesses[i + 1] == 0)
      line-drawing := ?
      if next-is-unmanaged:
        line-drawing = end
      else if use & MEMORY-PAGE-MERGE-WITH-NEXT_ != 0:
        line-drawing = allocation-continue
      else:
        line-drawing = allocation-end
      if symbols.size > 2 and not is-data-line:
        // Pad the line drawings on non-data lines to match the width of the
        // data.
        first-character := line-drawing[0..utf-8-bytes line-drawing[0]]
        line-drawing = (first-character * (symbols.size - 2)) + line-drawing
      line.add line-drawing
    result.add
        "  " + (line.join "")

class HeapReport extends Mirror:
  static tag ::= 'H'
  reason := ""
  pages ::= []

  constructor json program/Program? [--if-error]:
    reason = json[1]
    pages = json[2].map: decode-json_ it program --if-error=if-error
    pages.sort --in-place: | a b | a.address.compare-to b.address
    super json program

  stringify -> string:
    if pages.is-empty: return "$reason: empty heap"
    output := []
    output.add "$reason\n"
    pages.do:
      output.add it.stringify
    return (output.join "") + (BlackWhiteBlockOutputter_).key

  terminal-stringify -> string:
    if pages.is-empty: return "$reason: empty heap"
    output := []
    output.add "$reason\n"
    pages.do:
      output.add it.terminal-stringify
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
  static PAGE-HEADER_ ::= 24
  static PAGE_ ::= 4096

  constructor json program [--if-error]:
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
      usage-char := "?ABSTUFWH?EOP?W "[use]
      block.call offset repetitions usage-char (offset + repetitions == PAGE_)
      offset += repetitions
    if offset < PAGE_:
      block.call offset (PAGE_ - offset) ' ' true

  stringify -> string:
    return print_ false

  terminal-stringify -> string:
    return print_ true

  print_ color:
    allocations := 0
    largest-free := 0
    unused := 0
    do: | offset size usage-char last-flag |
      if usage-char != 'F' and usage-char != 'H' and usage-char != ' ': allocations++
      if usage-char == 'F':
        if size > largest-free: largest-free = size
        unused += size
    ram-type := 0x4008_0000 <= address < 0x400A_0000 ? "  (IRAM)" : ""
    result := "    0x$(%08x address): $(unused * 100 / 4096)% free, largest space $largest-free bytes, allocations: $allocations$ram-type\n"
    blocks := color ? ColorBlockOutputter_ : BlackWhiteBlockOutputter_
    do: | offset size usage-char last-flag |
      (size / GRANULARITY_).repeat: blocks.add usage-char (it == size / GRANULARITY_ - 1 and last-flag)
    return result + blocks.buffer

DESCRIPTIONS_ ::= {
  '?': "Misc",
  'A': "External byte array",
  'B': "Bignum (crypto)",
  'S': "External string",
  'T': "Toit GCed heap",
  'F': "Free",
  'W': "LwIP/WiFi",
  'H': "Malloc heap bookkeeping",
  'E': "Event sources",
  'O': "Other threads",
  'P': "Thread spawn",
  ' ': "Not part of the heap",
}

abstract class BlockOutputter_:
  atoms := 0
  abstract add usage-char last-flag
  abstract buffer

class CharacterBlockOutputter_ extends BlockOutputter_:
  buffer := ""

  add usage-char last-flag:
    buffer += "$(%c usage-char)"
    atoms++
    if atoms & 0x7f == 0: buffer += "\n"

abstract class UnicodeBlockOutputter_ extends BlockOutputter_:
  previous-usage := null
  buffer := "     $("▁" * 64)\n    ▕"

  increment-atoms last-flag reset [block]:
    atoms++
    if atoms & 0x7f == 0:
      buffer += last-flag ?  "$reset▏\n     $("▔" * 64)\n" : "$reset▏\n    ▕"
      block.call

  abstract key

class BlackWhiteBlockOutputter_ extends UnicodeBlockOutputter_:
  key:
    result := ""
    DESCRIPTIONS_.do: | letter description |
      letter-string := letter == 'F' ? "█" : "$(%c letter)"
      result += "    $(description.pad 30) $letter-string\n"
    return result

  add usage-char last-flag:
    if atoms & 1 == 0:
      previous-usage = usage-char
    else:
      atom-was-free := previous-usage == 'F' or previous-usage == 'H'
      new-atom-is-free := usage-char == 'F' or usage-char == 'H'
      if not atom-was-free:
        if not new-atom-is-free:
          buffer += "$(%c usage-char)"
        else:
          buffer += "▐"
      else:
        if not new-atom-is-free:
          buffer += "▌"
        else:
          buffer += "█"
    increment-atoms last-flag "": null

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
    'B': 111,  // Bignum.
    'S': 190,  // External string.
    'T': 214,  // Toit heap.
    'U': 112,  // Unused (spare) Toit heap.
    'F': 44,   // Cyan, free memory.
    'W': 170,  // Purple, LwIP/Wifi.
    'E': 89,   // Dark red, event sources.
    'O': 160,  // Bright red, other threads.
    'P': 20,   // Aquamarine, thread spawn.
    'H': 248,  // Heap overhead/headers.
    ' ': 15    // White, outside the heap.
  }

  key:
    result := ""
    DESCRIPTIONS_.do: | letter description |
      result += "    $BG$colors[letter]m $(description.pad 30) $(%c letter) $reset\n"
    return result

  reset ::= "\u001b[0m"

  add usage-char last-flag:
    if atoms & 1 == 0:
      previous-usage = usage-char
    else:
      new-background := colors[previous-usage]
      new-foreground := colors[usage-char]
      if new-background == new-foreground:
        if background != new-background:
          background = new-background
          buffer += "$BG$(background)m"
      if background == new-background and background == new-foreground:
        if foreground != 239:  // Dark grey
          foreground = 239
          buffer += "$FG$(foreground)m"
        buffer += "$(%c usage-char)"
      else:
        sequence := ""
        if background != new-background:
          sequence += "$BG$(new-background)m"
        if foreground != new-foreground:
          sequence += "$FG$(new-foreground)m"
        sequence += "▐"
        buffer += sequence
        foreground = new-foreground
        background = new-background

    increment-atoms last-flag reset:
      foreground = -1
      background = -1

decode json-payload/any program/Program? [--if-error]:
  return decode-json_ json-payload program --if-error=if-error

decode-json_ json program/Program? [--if-error]:
  // First recognize basic types.
  if json is num: return json
  if json is string: return json
  if json is ByteArray: return json
  if json is bool: return json
  if json == null: return null
  // Then decode a real list as a system encoded data structure.
  assert: not json is ByteArray // Note: a ByteArray is also a List.
  assert: json is List
  if json.size == 0: return if-error.call "Expecting a non empty list"
  tag := json.first
  if      tag == Array.tag:        return Array        json program --if-error=if-error
  else if tag == MList.tag:        return MList        json program --if-error=if-error
  else if tag == Stack.tag:        return Stack        json program --if-error=if-error
  else if tag == Frame.tag:        return Frame        json program --if-error=if-error
  else if tag == Error.tag:        return Error        json program --if-error=if-error
  else if tag == Instance.tag:     return Instance     json program --if-error=if-error
  else if tag == Profile.tag:      return Profile      json program --if-error=if-error
  else if tag == Histogram.tag:    return Histogram    json program --if-error=if-error
  else if tag == HeapReport.tag:   return HeapReport   json program --if-error=if-error
  else if tag == HeapPage.tag:     return HeapPage     json program --if-error=if-error
  else if tag == CoreDump.tag:     return CoreDump     json program --if-error=if-error
  else if tag == MallocReport.tag: return MallocReport json program --if-error=if-error
  return if-error.call "Unknown tag: $tag"
