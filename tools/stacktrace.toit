// Copyright (C) 2024 Toitware ApS.
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

import cli
import host.file
import host.pipe
import io

OBJDUMP ::= "xtensa-esp32-elf-objdump"

ELF-FILE ::= "elf-file"

main args/List:
  cmd := build-command
  cmd.run args

build-command -> cli.Command:
  cmd := cli.Command "stacktrace"
      --help="Decode an ESP-IDF backtrace message from the UART console."
      --rest=[cli.Option --required ELF-FILE --type="path"]
      --options=[
          cli.Flag "disassemble" --short-name="d",
          cli.Option "objdump" --default=OBJDUMP,
          cli.Option "backtrace" --default="-"
          ]
      --run=:: decode-stacktrace it
      --examples=[
        cli.Example """
          Read a stacktrace from the standard input and decode it using the default objdump and
          the 'build/esp32/toit.elf' file.
          The command could be prefixed with something like
          'echo Backtrace:0x400870c0:0x3ffc9df0 0x4010661d:0x3ffc9e70 0x401143a3:0x3ffc9ea0 |'
          """
          --arguments="build/esp32/toit.elf",
        cli.Example """
          Decode the given stacktrace the default objdump and the 'build/esp32s3/toit.elf' file:"""
          --arguments="--backtrace=\"Backtrace:0x400870c0:0x3ffc9df0 0x4010661d:0x3ffc9e70 0x401143a3:0x3ffc9ea0\" build/esp32s3/toit.elf"
      ]
  return cmd

decode-stacktrace invocation/cli.Invocation:
  disassemble := invocation["disassemble"]
  objdump-exe := invocation["objdump"]
  objdump / io.Reader? := null
  symbols-only := false
  elf-file := invocation[ELF-FILE]
  elf-size := file.size elf-file
  exception := catch:
    flags := disassemble ? "-dC" : "-tC"
    objdump = io.Reader.adapt
        pipe.from objdump-exe flags elf-file
    objdump.ensure-buffered (min 1000 elf-size) // Read once to see if objdump understands the file.
  if exception:
    throw "$exception: $objdump-exe"
  symbols := []
  disassembly-lines := {:}
  while line := objdump.read-line:
    if line.size < 11: continue
    if line[8] == ' ':
      address := int.parse --radix=16 line[0..8]
      if disassemble:
        // Line format: nnnnnnnn <symbol>:
        if line[9] != '<': continue
        if not line.ends-with ">:": continue
        name := line[10..line.size - 2].copy
        symbol := Symbol address name
        symbols.add symbol
      else:
        // Line format: nnnnnnnn flags   section   	size     <name>
        tab := line.index-of "\t"
        if tab == -1: continue
        name := tab + 10
        if name >= line.size: continue
        symbol := Symbol address line[name..]
        symbols.add symbol
    else if disassemble and line[8] == ':':
      // Line format: nnnnnnnn:      0898    l32i.n  a9, a8, 0
      8.repeat:
        if not '0' <= line[it] <= '9' and not 'a' <= line[it] <= 'f': continue
      address := int.parse --radix=16 line[0..8]
      disassembly-lines[address] = line

  backtrace / string? := null
  if invocation["backtrace"] == "-":
    error := catch:
      with-timeout --ms=2000:
        backtrace = (io.Reader.adapt pipe.stdin).read-line
    if error == "DEADLINE_EXCEEDED":
      throw "Timed out waiting for stdin"
    if error:
      throw error
  else:
    backtrace = invocation["backtrace"]
    if not (backtrace.starts-with "Backtrace:"):
      backtrace = "Backtrace:$backtrace"

  /* Sample output without --disassemble:
  0x400870c0: toit::Interpreter::_run() + 0x132c
  0x4010661d: toit::Interpreter::run() + 0x9
  0x401143a3: toit::Scheduler::run_process(toit::Locker&, toit::Process*, toit::SchedulerThread*) + 0x57
  0x40114592: toit::Scheduler::run(toit::SchedulerThread*) + 0x42
  0x401145c5: toit::SchedulerThread::entry() + 0x9
  0x40108262: toit::Thread::_boot() + 0x22
  0x40108289: toit::thread_start(void*) + 0x5
  */

  /* Sample output with --disassemble:
  0x400870c0: toit::Interpreter::_run() + 0x132c
  ...
    400870b8:	102192        	l32i	a9, a1, 64
    400870bb:	1133f0        	slli	a3, a3, 1
    400870be:	142952        	l32i	a5, a9, 80
  * 400870c0:  (address is inside previous instruction)
    400870c1:	353a      	add.n	a3, a5, a3

  0x4010661d: toit::Interpreter::run() + 0x9
    4010661a:	2de681        	l32r	a8, 400d1db4 <ram_en_pwdet+0xb6c>
  * 4010661d:	0008e0        	callx8	a8
    40106620:	0a2d      	mov.n	a2, a10
  ...
  */
  backtrace-do backtrace symbols: | address symbol |
    name := "(unknown)"
    if disassemble: print ""
    if symbol:
      name = "$symbol.name + 0x$(%x address - symbol.address)"
    print "0x$(%x address): $name"
    if symbol and disassemble:
      star-printed := false
      start := max symbol.address (address - 30)
      if start != symbol.address: print "..."
      for add := start; add < address + 15; add++:
        star := " "
        if not star-printed and add >= address:
          if disassembly-lines.contains add:
            star = "*"
          else:
            print "* $(%x add):  (address is inside previous instruction)"
          star-printed = true
        if disassembly-lines.contains add:
          print "$star $disassembly-lines[add]"
    if disassemble: print ""

backtrace-do backtrace/string symbols/List [block]:
  if not backtrace.starts-with "Backtrace:":
    print "Invalid backtrace: $backtrace. Doesn't start with 'Backtrace:'"
    throw "INVALID_BACKTRACE"
  backtrace[10..].split " ": | pair |
    if pair.contains ":":
      if not pair.starts-with "0x":
        throw "Can't parse address: $pair"
      address := int.parse --radix=16 pair[2..pair.index-of ":"]
      symbol := null
      symbols.do: | candidate |
        if candidate.address <= address and (not symbol or candidate.address > symbol.address):
          symbol = candidate
      block.call address symbol

class Symbol:
  address / int
  name / string

  constructor .address .name:

  stringify: return "$address: $name"
