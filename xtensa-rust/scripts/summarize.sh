#!/usr/bin/env bash
# Summarizes link/out/*/{verify,run,both}.components.txt into
# link/out/summary.txt (bytes; text includes Xtensa literal pools).
set -uo pipefail
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust
{
  echo "Dummy ELF, --gc-sections; bytes (text incl. literal pools + rodata)"
  printf "%-6s %-7s %8s %8s %8s %8s %8s %8s %8s %8s\n" cfg keep spec core vmverify core+alloc builtins strings C total
  for a in xt rv; do
    for o in s z 3; do
      for k in verify run both; do
        f=$ROOT/link/out/$a-$o/$k.components.txt
        g() { awk -v c="$1" 'substr($0, 1, length(c)) == c {print $NF; found = 1} END {if (!found) print 0}' "$f"; }
        cc=$(( $(g 'libc (C)') + $(g 'libgcc (C)') + $(g 'libm (C)') + $(g 'C dummy+stubs') + $(g other) ))
        printf "%-6s %-7s %8s %8s %8s %8s %8s %8s %8s %8s\n" "$a-$o" "$k" "$(g toit_spec)" "$(g toit_verified_core)" \
          "$(g toit_vmverify)" "$(( $(g 'core ') + $(g 'alloc ') + $(g 'rust (unnamed') ))" "$(g compiler_builtins)" \
          "$(g 'rust strings')" "$cc" "$(g TOTAL)"
      done
    done
  done
  echo
  for a in xt rv; do for o in s z 3; do cat "$ROOT/link/out/$a-$o/build-time.txt"; done; done
} | tee "$ROOT/link/out/summary.txt"
