#!/usr/bin/env bash
# Runs link-dummy.sh for {xt,rv} x {s,z,3} x {verify,run,both} from clean
# builds and writes link/out/summary.txt.
set -euo pipefail
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust
S=$ROOT/scripts
rm -rf "$ROOT/devlib-target" "$ROOT/link/out"
for a in xt rv; do
  for o in s z 3; do
    for k in verify run both; do
      bash "$S/link-dummy.sh" $a $o $k > /dev/null
    done
  done
done
{
  echo "Dummy ELF, --gc-sections; text includes literal pools; KB = 1000 bytes"
  printf "%-6s %-7s %10s %10s %10s %10s %10s %10s %10s\n" cfg keep spec core vmverify core+alloc builtins strings total
  for a in xt rv; do
    for o in s z 3; do
      for k in verify run both; do
        f=$ROOT/link/out/$a-$o/$k.components.txt
        g() { awk -v c="$1" '$1 == c {print $4}' "$f"; }
        printf "%-6s %-7s %10s %10s %10s %10s %10s %10s %10s\n" "$a-$o" "$k" "$(g toit_spec)" "$(g toit_verified_core)" \
          "$(g toit_vmverify)" "$(( $(g core || echo 0) + $(g alloc || echo 0) ))" "$(g compiler_builtins)" \
          "$(g 'rust strings/anon' || true)" "$(g TOTAL)"
      done
    done
  done
  echo
  for a in xt rv; do for o in s z 3; do cat "$ROOT/link/out/$a-$o/build-time.txt"; done; done
} | tee "$ROOT/link/out/summary.txt"
