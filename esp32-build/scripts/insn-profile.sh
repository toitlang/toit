#!/usr/bin/env bash
# Per-handler instruction profile of toit::Interpreter::run on the host:
# runs a benchmark under callgrind with per-instruction costs, compiles
# interpreter_run.cc of SOURCE-ROOT with the host command plus -g (same
# code), maps each executed instruction to the outermost source line in
# interpreter_run.cc (addr2line -i) and sums the costs per opcode handler
# (the enclosing OPCODE_BEGIN or label).
# Usage: insn-profile.sh LABEL TOIT.RUN SOURCE-ROOT BENCH
set -e
LABEL=$1; BIN=$2; ROOT=$(cd "$3" && pwd); BENCH=$4
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
OUT=$A/prof/$LABEL.$BENCH
mkdir -p "$OUT"
valgrind --tool=callgrind --dump-instr=yes "--toggle-collect=toit::Interpreter::run()" \
  --callgrind-out-file="$OUT/cg" "$BIN" "$A/snap/$BENCH-f1.snap" > "$OUT/run.out" 2>&1
# Self cost per instruction address of run().
awk '
  function fname(s,   id, rest) {
    if (match(s, /^\(([0-9]+)\) ?(.*)$/, m)) { id = m[1]; rest = m[2]; if (rest != "") names[id] = rest; return names[id] }
    return s
  }
  /^fn=/ { infn = (fname(substr($0, 4)) ~ /Interpreter::run\(\)/); next }
  /^cfn=/ { fname(substr($0, 5)); next }
  /^(cfi|cob|calls)=/ { if ($0 ~ /^calls=/) skip = 1; next }
  /^(fl|fi|fe|ob)=/ { next }
  /^(0x[0-9a-f]+|[+-][0-9]+|\*)/ {
    a = $1
    if (a ~ /^0x/) addr = strtonum(a); else if (a ~ /^\+/) addr += strtonum(substr(a, 2)); else if (a ~ /^-/) addr -= strtonum(substr(a, 2));
    if (skip) { skip = 0; next }
    if (infn && NF >= 3) cost[addr] += $3
  }
  END { for (k in cost) printf "%x %d\n", k, cost[k] }
' "$OUT/cg" | sort > "$OUT/addr-cost.txt"
START=$(nm -C "$BIN" | grep ' toit::Interpreter::run()$' | awk '{print $1}')
# The object with debug info.
CMD=$(grep -B3 "\"file\": \"$WT/src/interpreter_run.cc\"" "$WT/build/host/compile_commands.json" | grep '"command"' | grep toit_vm.dir | head -1 \
  | sed -e 's/^ *"command": "//' -e 's/",$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
CMD=${CMD//-I$WT\/src/-I$ROOT\/src}
CMD=${CMD//-I$WT\/include/-I$ROOT\/include}
CMD=$(echo "$CMD" | sed -e "s| -o [^ ]*| -o $OUT/run.o|" -e "s| -c [^ ]*| -c $ROOT/src/interpreter_run.cc|")
(cd "$WT/build/host" && eval "$CMD -g")
OSTART=$(nm -C "$OUT/run.o" | grep ' toit::Interpreter::run()$' | awk '{print $1}')
awk -v s="$START" -v o="$OSTART" '{ printf "0x%x %s\n", strtonum("0x" $1) - strtonum("0x" s) + strtonum("0x" o), $2 }' "$OUT/addr-cost.txt" > "$OUT/obj-cost.txt"
cut -d' ' -f1 "$OUT/obj-cost.txt" | addr2line -a -i -e "$OUT/run.o" -j ".text._ZN4toit11Interpreter3runEv" > "$OUT/lines.raw"
# Address -> outermost line in interpreter_run.cc.
awk '/^0x/ { if (addr != "") print addr, best; addr = sprintf("0x%x", strtonum($1)); best = "?"; next }
     /interpreter_run.cc:/ { split($0, p, ":"); best = p[2] + 0 }
     END { if (addr != "") print addr, best }' "$OUT/lines.raw" > "$OUT/addr-line.txt"
# Line -> handler (the last OPCODE_BEGIN or label before it).
awk '{ if (match($0, /OPCODE_BEGIN(_WITH_WIDE)?\(([A-Z_0-9]+)/, m)) h = m[2];
       else if (match($0, /^  ([A-Za-z_0-9]+):/, m)) h = m[1];
       else if (match($0, /^(Interpreter::Result Interpreter::run|Object\*\* Interpreter::hash_find|Object\* Interpreter::hash_do)/, m)) h = m[1];
       print NR, h }' "$ROOT/src/interpreter_run.cc" > "$OUT/line-handler.txt"
awk 'FILENAME == ARGV[1] { h[$1] = $2; next }
     FILENAME == ARGV[2] { line[$1] = $2; next }
     { l = line[sprintf("0x%x", strtonum($1))]; name = (l in h) ? h[l] : "?" l; s[name] += $2; t += $2 }
     END { for (k in s) printf "%12d %s\n", s[k], k; printf "%12d TOTAL\n", t }' \
  "$OUT/line-handler.txt" "$OUT/addr-line.txt" "$OUT/obj-cost.txt" | sort -rn > "$OUT/handlers.txt"
head -40 "$OUT/handlers.txt"
