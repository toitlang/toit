import host.file
import host.pipe
import host.arguments
import reader show BufferedReader

usage:
  print "Usage: echo Backtrace:0x400870c0:0x3ffc9df0 0x4010661d:0x3ffc9e70 0x401143a3:0x3ffc9ea0 | toit.run stacktrace.toit [--disassemble] [--objdump objdump_executable] /path/to/toit.elf"
  exit 1

OBJDUMP ::= "xtensa-esp32-elf-objdump"

main args/List:
  parser := arguments.ArgumentParser
  parser.describe_rest ["/path/to/toit.elf"]
  parser.add_flag "disassemble" --short="d"
  parser.add_option "objdump" --default=OBJDUMP
  parsed := parser.parse args:
    usage
    exit 1
  if args.size < 1: usage
  disassemble := parsed["disassemble"]
  objdump_exe := parsed["objdump"]
  objdump / BufferedReader? := null
  symbols_only := false
  elf_file := parsed.rest[0]
  elf_size := file.size elf_file
  exception := catch:
    flags := disassemble ? "-dC" : "-tC"
    objdump = BufferedReader
        pipe.from objdump_exe flags elf_file
    objdump.ensure (min 1000 elf_size) // Read once to see if objdump understands the file.
  if exception:
    throw "$exception: $objdump_exe"
  symbols := []
  disassembly_lines := {:}
  while line := objdump.read_line:
    if line.size < 11: continue
    if line[8] == ' ':
      address := int.parse --radix=16 line[0..8]
      if disassemble:
        // Line format: nnnnnnnn <symbol>:
        if line[9] != '<': continue
        if not line.ends_with ">:": continue
        name := line[10..line.size - 2].copy
        symbol := Symbol address name
        symbols.add symbol
      else:
        // Line format: nnnnnnnn flags   section   	size     <name>
        tab := line.index_of "\t"
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
      disassembly_lines[address] = line

  backtrace / string? := null
  error := catch:
    with_timeout --ms=2000:
      backtrace = (BufferedReader pipe.stdin).read_line
  if error == "DEADLINE_EXCEEDED":
    print "Timed out waiting for stdin"
    usage
  if error:
    throw error

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
  backtrace_do backtrace symbols: | address symbol |
    name := "(unknown)"
    if disassemble: print ""
    if symbol:
      name = "$symbol.name + 0x$(%x address - symbol.address)"
    print "0x$(%x address): $name"
    if symbol and disassemble:
      star_printed := false
      start := max symbol.address (address - 30)
      if start != symbol.address: print "..."
      for add := start; add < address + 15; add++:
        star := " "
        if not star_printed and add >= address:
          if disassembly_lines.contains add:
            star = "*"
          else:
            print "* $(%x add):  (address is inside previous instruction)"
          star_printed = true
        if disassembly_lines.contains add:
          print "$star $disassembly_lines[add]"
    if disassemble: print ""

backtrace_do backtrace/string symbols/List [block]:
  if not backtrace.starts_with "Backtrace:": usage
  backtrace[10..].split " ": | pair |
    if pair.contains ":":
      if not pair.starts_with "0x":
        throw "Can't parse address: $pair"
      address := int.parse --radix=16 pair[2..pair.index_of ":"]
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
