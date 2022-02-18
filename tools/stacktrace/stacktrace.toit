import host.pipe
import reader show BufferedReader

usage:
  print "Usage: echo Backtrace:0x400870c0:0x3ffc9df0 0x4010661d:0x3ffc9e70 0x401143a3:0x3ffc9ea0 | toit.run stacktrace.toit [--disassemble] /path/to/toit.elf"
  exit 1

main args/List:
  if args.size < 1: usage
  disassemble := false
  if args[0] == "--disassemble":
    disassemble = true
    args = args[1..]
  if args.size != 1: usage
  objdump := BufferedReader
      pipe.from "xtensa-esp32-elf-objdump" "-dC" args[0]
  symbols := []
  disassembly_lines := {:}
  while line := objdump.read_line:
    if line.size < 11: continue
    if line[8] == ' ':
      // Line format: nnnnnnnn <symbol>:
      if line[9] != '<': continue
      if not line.ends_with ">:": continue
      name := line[10..line.size - 2].copy
      address := int.parse --radix=16 line[0..8]
      symbol := Symbol address name
      symbols.add symbol
    else if line[8] == ':':
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

  if not disassemble:
    backtrace_do backtrace symbols: | address symbol |
      name := "(unknown)"
      if symbol:
        name = "$symbol.name + 0x$(%x address - symbol.address)"
      print "0x$(%x address): $name"

  else:
    backtrace_do backtrace symbols: | address symbol |
      name := "(unknown)"
      print ""
      if symbol:
        name = "$symbol.name + 0x$(%x address - symbol.address)"
      print "0x$(%x address): $name"
      if symbol:
        star_printed := false
        start := max symbol.address address - 30
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
      print ""

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
