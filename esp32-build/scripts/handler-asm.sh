#!/usr/bin/env bash
# The executed instructions of one handler with their costs (insn-profile.sh
# output). Usage: handler-asm.sh PROF HANDLER [MIN-COST]
P=/home/flo/work/opentoit-sandbox-artifacts/esp32-build/prof/$1
H=$2
MIN=${3:-100000}
objdump -d --no-show-raw-insn -C -j .text._ZN4toit11Interpreter3runEv "$P/run.o" > "$P/run.dis" 2>/dev/null
awk -v h="$H" -v min="$MIN" '
  FILENAME == ARGV[1] { hand[$1] = $2; next }
  FILENAME == ARGV[2] { line[$1] = $2; next }
  FILENAME == ARGV[3] { if ($2 >= min && hand[line[$1]] == h) want[strtonum($1)] = $2 " L" line[$1]; next }
  /^ *[0-9a-f]+:/ { a = strtonum("0x" substr($1, 1, length($1) - 1)); if (a in want) printf "%-14s %s\n", want[a], $0 }
' "$P/line-handler.txt" "$P/addr-line.txt" "$P/obj-cost.txt" "$P/run.dis"
