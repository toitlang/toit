#!/usr/bin/env toit.run

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

// Tools for decoding a snapshot.
import .snapshot
import host.arguments show *

usage --exit_code:
  print "Usage:"
  print "  toitp"
  print "    [--help|-h]"
  print "    [--literals|-l]"
  print "    [--literal <id>]"
  print "    [--classes|-c]"
  print "    [--dispatch_table|-d]"
  print "    [--method_table|-m]"
  print "    [--method_sizes]"
  print "    [--bytecodes|-bc]"
  print "    [--senders|-s]"
  print "    <snapshot-path> [filter]"
  exit exit_code

matching name:
  if filter == "": return true
  return name.glob filter

qualifier:
  return filter == "" ? "" : " (only printing elements matching: \"$filter\")"

print_collection title collection program [filter] [stringify]:
  print "$(title)[$(collection.size)]:$qualifier"
  collection.size.repeat:
    | index |
    element := collection[index]
    if filter.call element index: print "$(%3d index): $(stringify.call element index)"
  print

print_classes program/Program:
  print_collection "Classes" program.class_tags program
    : | _ id | matching (program.class_name_for id)
    : | _ id | (program.class_info_for id).stringify

print_literals program/Program:
  print_collection "Literals" program.literals program
    : matching (it.stringify)
    : it

print_literal program/Program index_str/string:
  index := int.parse index_str --on_error=:
    print "Argument to '--literal' must be an integer."
    usage --exit_code=1
  if not 0 <= index < program.literals.size:
    print "Invalid index."
    exit 1
  print program.literals[index]

print_dispatch_table program/Program:
  // The dispatch entry contains either an integer or a method.
  print_collection "Dispatch Table" program.dispatch_table program
    : filter == "" or (it != -1 and matching (program.method_name_for it))
    : it == -1 ? "<empty>" : (program.method_info_for it).stringify program

print_method_table program/Program:
  print "Method Table[$(program.method_info_size)]:$qualifier"
  program.do --method_infos: | method_info/MethodInfo |
    if matching method_info.name:
      print "$(%5d method_info.id): $(method_info.stringify program)"

print_method_sizes program/Program:
  print "Method Table[$(program.method_info_size)]:$qualifier"
  program.do --method_infos: | method_info/MethodInfo |
    if matching method_info.name:
      print "$(method_info.bytecode_size) $(method_info.prefix_string program) $(method_info.error_path)"

print_primitive_table program/Program:
  modules := program.primitive_table
  size := 0
  modules.do: size += it.primitives.size
  print "Primitive Table:$qualifier"
  modules.size.repeat:
    | module_index |
    modules[module_index].primitives.size.repeat:
      | primitive_index |
      name := program.primitive_name module_index primitive_index
      if matching name: print "  {$name}"
  print

print_bytecodes program/Program:
  methods/List := ?
  suffix := ?
  absolute_bci := int.parse filter --on_error=:-1
  if absolute_bci >= 0:
    methods = [program.method_from_absolute_bci absolute_bci]
    suffix = " (only printing methods containing absolute bci $absolute_bci)"
  else:
    methods = program.methods
    methods = methods.filter:
      (program.method_name_for it.id).contains filter
    suffix = qualifier
  print "Bytecodes for methods[$(methods.size)]:$suffix"
  print
  methods.do: it.output program

has_call program method:
  method.do_calls program: if matching it: return true
  return false

print_senders program bc:
  methods := program.methods
  methods = methods.filter: has_call program it
  print "Methods with calls to \"$filter\"[$(methods.size)]:"
  methods.do:
    if bc: it.output program
    else: print (it.stringify program)


filter := ""

main args:
  parser := ArgumentParser
  parser.describe_rest ["snapshot-file", "[filter]"]
  parser.add_flag "help"            --short="h"
  parser.add_flag "literals"        --short="l"
  parser.add_option "literal"
  parser.add_flag "classes"         --short="c"
  parser.add_flag "dispatch_table"  --short="d"
  parser.add_flag "method_table"    --short="m"
  parser.add_flag "method_sizes"
  parser.add_flag "bytecodes"       --short="bc"
  parser.add_flag "senders"         --short="s"
  parser.add_flag "primitive_table" --short="p"

  parsed := parser.parse args
  if parsed["help"]: usage --exit_code=0
  if parsed.rest.size > 1: filter = parsed.rest[1]
  snapshot := SnapshotBundle.from_file parsed.rest[0]
  program := snapshot.decode

  if parsed["classes"]:         print_classes program; return
  if parsed["literals"]:        print_literals program; return
  if parsed["literal"]:         print_literal program parsed["literal"]; return
  if parsed["dispatch_table"]:  print_dispatch_table program; return
  if parsed["method_table"]:    print_method_table program; return
  if parsed["method_sizes"]:    print_method_sizes program; return
  if parsed["primitive_table"]: print_primitive_table program; return
  if parsed["senders"]:         print_senders program parsed["bytecodes"]; return
  if parsed["bytecodes"]:       print_bytecodes program; return
  print snapshot.stringify
