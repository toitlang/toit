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

has-call program/Program method/ToitMethod:
  method.do-calls program: if matching it: return true
  return false

print-senders program/Program bc:
  methods := program.methods
  methods = methods.filter: has-call program it
  print "Methods with calls to \"$filter\"[$(methods.size)]:"
  methods.do:
    if bc: it.output program
    else: print (it.stringify program)

print-uuid snapshot/SnapshotBundle:
  print "$snapshot.uuid"

print-sizes snapshot/SnapshotBundle:
  print """
    uuid: $snapshot.uuid
    size: $snapshot.bytes.size bytes
     - $snapshot.program-snapshot
    $(snapshot.source-map ? " - $snapshot.source-map" : "")"""

filter := ""

with-filtered-cli-program invocation/cli.Invocation [block]:
  filter = invocation["filter"] or ""
  snapshot := SnapshotBundle.from-file invocation["snapshot"]
  program := snapshot.decode
  block.call program

is-number-string str/string -> bool:
  if str.size == 0: return false
  str.size.repeat:
    if not '0' <= str[it] <= '9': return false
  return true

build-command -> cli.Command:
  snapshot-command := cli.Command "snapshot"
      --help="""
          Inspect a Toit snapshot.
          """

  snapshot-option := cli.Option "snapshot"
      --help="The snapshot to inspect."
      --type="file"
      --required
  filter-option := cli.Option "filter"
      --help="Only print elements matching the filter pattern."
  filter-help := """
          The optional filter pattern is a glob pattern, where '*' matches any sequence of
          characters and '?' matches any single character. The filter is case-sensitive."""

  literals-command := cli.Command "literals"
      --help="""
          Print the literals in the snapshot.

          The filter can either be a literal index or a glob pattern, where '*' matches any
          sequence of characters and '?' matches any single character. The filter is case-sensitive.
          """
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print all literals of snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
        cli.Example "Print all literals starting with 'http://':"
            --arguments="foo.snapshot 'http://*'",
        cli.Example "Print the literal with id 42:"
            --arguments="foo.snapshot 42",
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            filter-arg := invocation["filter"]
            if filter-arg and is-number-string filter-arg:
              // Ignore the filter argument if it is a number.
              print-literal program (int.parse filter-arg)
            else:
              print-literals program
  snapshot-command.add literals-command

  classes-command := cli.Command "classes"
      --help="""
          Print the classes in the snapshot.

          $filter-help
          """
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print all classes of snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
        cli.Example "Print all classes ending with 'Handler':"
            --arguments="foo.snapshot '*Handler'",
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            print-classes program
  snapshot-command.add classes-command

  dispatch-table-command := cli.Command "dispatch-table"
      --help="""
          Print the dispatch table in the snapshot.

          $filter-help
          """
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print the dispatch table of snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
        cli.Example "Print the dispatch table restricted to methods containing 'bar' in their name:"
            --arguments="foo.snapshot '*bar*'"
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            print-dispatch-table program
  snapshot-command.add dispatch-table-command

  method-table-command := cli.Command "method-table"
      --help="""
          Print the method table in the snapshot.

          $filter-help
          """
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print the method table of snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
        cli.Example "Print the method table for methods containing 'bar' in their name:"
            --arguments="foo.snapshot '*bar*'"
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            print-method-table program
  snapshot-command.add method-table-command

  method-sizes-command := cli.Command "method-sizes"
      --help="""
          Print the method sizes in the snapshot.

          $filter-help
          """
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print the method sizes of snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
        cli.Example "Print the method sizes for methods containing 'bar' in their name:"
            --arguments="foo.snapshot '*bar*'"
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            print-method-sizes program
  snapshot-command.add method-sizes-command

  primitive-table-command := cli.Command "primitive-table"
      --help="""
          Print the primitive table in the snapshot.

          $filter-help
          """
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print the primitive table of snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
        cli.Example "Print the primitive table for primitives containing 'bar' in their name:"
            --arguments="foo.snapshot '*bar*'"
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            print-primitive-table program
  snapshot-command.add primitive-table-command

  senders-command := cli.Command "callers"
      --help="""
          Print the methods that call another method.

          $filter-help
          """
      --options=[
        cli.Flag "bytecodes" --short-name="bc" --help="Print the bytecodes of the methods."
      ]
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print the methods that call the method 'bar':"
            --arguments="foo.snapshot bar",
        cli.Example "Print the methods that call methods that have 'bar' in their name:"
            --arguments="foo.snapshot '*bar*'",
        cli.Example "Print the bytecodes of all methods that call 'gee':"
            --arguments="foo.snapshot gee --bytecodes",
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            print-senders program invocation["bytecodes"]
  snapshot-command.add senders-command

  bytecodes-command := cli.Command "bytecodes"
      --help="""
          Print the bytecodes of the methods in the snapshot.

          $filter-help
          """
      --rest=[snapshot-option, filter-option]
      --examples=[
        cli.Example "Print the bytecodes of all methods in snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
        cli.Example "Print the bytecodes for methods containing 'bar' in their name:"
            --arguments="foo.snapshot '*bar*'"
      ]
      --run=:: | invocation/cli.Invocation |
          with-filtered-cli-program invocation: | program/Program |
            print-bytecodes program
  snapshot-command.add bytecodes-command

  uuid-command := cli.Command "uuid"
      --help="Print the UUID of the snapshot."
      --rest=[snapshot-option]
      --examples=[
        cli.Example "Print the UUID of snapshot 'foo.snapshot':"
            --arguments="foo.snapshot",
      ]
      --run=:: | invocation/cli.Invocation |
        snapshot := SnapshotBundle.from-file invocation["snapshot"]
        print-uuid snapshot
  snapshot-command.add uuid-command

  return snapshot-command

main args:
  parameters/cli.Parameters? := null
  parser := cli.Command "toitp"
      --rest=[
          cli.Option "snapshot" --type="file" --required,
          cli.Option "filter",
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
          cli.Flag "uuid",
      ]
      --run=:: parameters = it.parameters
  parser.run args
  if not parameters: exit 0

  if parameters["filter"]: filter = parameters["filter"]
  snapshot := SnapshotBundle.from-file parameters["snapshot"]
  program := snapshot.decode

  if parameters["classes"]:         print-classes program; return
  if parameters["literals"]:        print-literals program; return
  if parameters["literal"]:         print-literal program parameters["literal"]; return
  if parameters["dispatch_table"]:  print-dispatch-table program; return
  if parameters["method_table"]:    print-method-table program; return
  if parameters["method_sizes"]:    print-method-sizes program; return
  if parameters["primitive_table"]: print-primitive-table program; return
  if parameters["senders"]:         print-senders program parameters["bytecodes"]; return
  if parameters["bytecodes"]:       print-bytecodes program; return
  if parameters["uuid"]:            print-uuid snapshot; return
  // For compatibility reasons print the sizes.
  print-sizes snapshot
