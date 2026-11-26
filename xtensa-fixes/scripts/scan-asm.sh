#!/usr/bin/env bash
# Scans objdump disassembly (one or more .dis files) for the instruction
# patterns of the known Xtensa wrong-code bugs:
#   SP-WRITE      any instruction other than entry/movsp/retw that writes a1
#                 (llvm#140: realignment with add/sub/and on a1)
#   MOVSP         every movsp, with the source's computation when it is
#                 `addi aX, a1, N`: misaligned when N % 16 != 0 (llvm#142)
#   (the FP variant of llvm#140 also writes a1 with add: SP-WRITE)
#   ENTRY-ODD     entry frame sizes that are not multiples of 16
# and counts the function prologues, calls (callx8/call8) and literal loads.
# Exit status 1 if any bad pattern is found.
# Usage: scan-asm.sh <file.dis>...
set -euo pipefail
awk '
  /^Disassembly of section / { lit = ($4 ~ /^\.literal/); next }
  lit { next }
  /^[0-9a-f]+ <.*>:$/ { fn = $2; since_entry = 99; nfn++; next }
  {
    # objdump line: "  addr:\tmnemonic\toperands"
    line = $0
    sub(/^ *[0-9a-f]+:\t/, "", line)
    split(line, p, "\t")
    m = p[1]; ops = p[2]
    gsub(/ /, "", ops)
    n = split(ops, o, ",")
  }
  m == "entry" {
    since_entry = 0
    if ((o[2] + 0) % 16 != 0) { print "ENTRY-ODD " fn " " line; bad++ }
    next
  }
  { since_entry++ }
  m ~ /^callx?(4|8|12)$/ { calls[m]++ }
  m == "l32r" { l32r++ }
  m == "movsp" {
    nmovsp++
    src = o[2]
    if (src in addi_from_sp) {
      off = addi_from_sp[src]
      if (off % 16 != 0) { print "MOVSP-MISALIGNED " fn " offset " off; bad++ }
      else movsp_ok++
    } else { print "MOVSP-OTHER " fn " " line; other_movsp++ }
    next
  }
  m == "addi" || m == "addi.n" {
    if (o[2] == "a1") addi_from_sp[o[1]] = o[3] + 0; else delete addi_from_sp[o[1]]
  }
  # Instructions that write a1 (first operand is the destination for ALU ops).
  n >= 1 && o[1] == "a1" && m !~ /^(entry|movsp|retw|retw\.n|s32i|s32i\.n|s16i|s8i|s32e|ssi|ssip|bnez|beqz|bnez\.n|beqz\.n|bltz|bgez|bne|beq|blt|bge|bltu|bgeu|bany|bnone|ball|bnall|bbc|bbs|bbci|bbsi|bnei|beqi|bgei|blti|bltui|bgeui|bgez|bltz|wsr.*|wur.*|wfr|s32c1i)$/ {
    print "SP-WRITE " fn " " line; bad++
  }
  END {
    printf "functions=%d calls: callx8=%d call8=%d callx4=%d callx12=%d l32r=%d movsp=%d (aligned addi %d, other %d) bad=%d\n",
      nfn, calls["callx8"], calls["call8"], calls["callx4"], calls["callx12"], l32r, nmovsp, movsp_ok, other_movsp, bad + 0
    exit (bad > 0)
  }
' "$@"
