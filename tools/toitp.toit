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
import cli

matching name:
  if filter == "": return true
  return name.glob filter

qualifier:
  return filter == "" ? "" : " (only printing elements matching: \"$filter\")"

print-collection title collection program [filter] [stringify]:
  print "$(title)[$(collection.size)]:$qualifier"
  collection.size.repeat:
    | index |
    element := collection[index]
    if filter.call element index: print "$(%3d index): $(stringify.call element index)"
  print

print-classes program/Program:
  print-collection "Classes" program.class-tags program
    : | _ id | matching (program.class-name-for id)
    : | _ id | (program.class-info-for id).stringify

print-literals program/Program:
  print-collection "Literals" program.literals program
    : matching (it.stringify)
    : it

print-literal program/Program index/int:
  if not 0 <= index < program.literals.size:
    print "Invalid index."
    exit 1
  print program.literals[index]

print-dispatch-table program/Program:
  // The dispatch entry contains either an integer or a method.
  print-collection "Dispatch Table" program.dispatch-table program
    : filter == "" or (it != -1 and matching (program.method-name-for it))
    : it == -1 ? "<empty>" : (program.method-info-for it).stringify program

print-method-table program/Program:
  print "Method Table[$(program.method-info-size)]:$qualifier"
  program.do --method-infos: | method-info/MethodInfo |
    if matching method-info.name:
      print "$(%5d method-info.id): $(method-info.stringify program)"

print-method-sizes program/Program:
  print "Method Table[$(program.method-info-size)]:$qualifier"
  program.do --method-infos: | method-info/MethodInfo |
    if matching method-info.name:
      print "$(method-info.bytecode-size) $(method-info.prefix-string program) $(method-info.error-path)"

print-primitive-table program/Program:
  modules := program.primitive-table
  size := 0
  modules.do: size += it.primitives.size
  print "Primitive Table:$qualifier"
  modules.size.repeat:
    | module-index |
    modules[module-index].primitives.size.repeat:
      | primitive-index |
      name := program.primitive-name module-index primitive-index
      if matching name: print "  {$name}"
  print

print-bytecodes program/Program:
  methods/List := ?
  suffix := ?
  absolute-bci := -1
  if not filter.is-empty: absolute-bci = int.parse filter --on-error=: -1
  if absolute-bci >= 0:
    methods = [program.method-from-absolute-bci absolute-bci]
    suffix = " (only printing methods containing absolute bci $absolute-bci)"
  else:
    methods = program.methods
    methods = methods.filter:
      (program.method-name-for it.id).contains filter
    suffix = qualifier
  print "Bytecodes for methods[$(methods.size)]:$suffix"
  print
  methods.do: it.output program

has-call program method:
  method.do-calls program: if matching it: return true
  return false

print-senders program bc:
  methods := program.methods
  methods = methods.filter: has-call program it
  print "Methods with calls to \"$filter\"[$(methods.size)]:"
  methods.do:
    if bc: it.output program
    else: print (it.stringify program)


filter := ""

main args:
  parsed := null
  parser := cli.Command "toitp"
      --rest=[
          cli.OptionString "snapshot" --type="file" --required,
          cli.OptionString "filter",
      ]
      --options=[
          cli.Flag "literals"        --short-name="l",
          cli.OptionInt "literal",
          cli.Flag "classes"         --short-name="c",
          cli.Flag "dispatch_table"  --short-name="d",
          cli.Flag "method_table"    --short-name="m",
          cli.Flag "method_sizes",
          cli.Flag "bytecodes"       --short-name="bc",
          cli.Flag "senders"         --short-name="s",
          cli.Flag "primitive_table" --short-name="p",
      ]
      --run=:: parsed = it
  parser.run args
  if not parsed: exit 0

  if parsed["filter"]: filter = parsed["filter"]
  snapshot := SnapshotBundle.from-file parsed["snapshot"]
  program := snapshot.decode

  if parsed["classes"]:         print-classes program; return
  if parsed["literals"]:        print-literals program; return
  if parsed["literal"]:         print-literal program parsed["literal"]; return
  if parsed["dispatch_table"]:  print-dispatch-table program; return
  if parsed["method_table"]:    print-method-table program; return
  if parsed["method_sizes"]:    print-method-sizes program; return
  if parsed["primitive_table"]: print-primitive-table program; return
  if parsed["senders"]:         print-senders program parsed["bytecodes"]; return
  if parsed["bytecodes"]:       print-bytecodes program; return
  print snapshot.stringify
