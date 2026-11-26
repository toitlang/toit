#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Writes qemu/progs/benches.toit (the benchmarks of suite.toit as a library)
# and one program per benchmark (bench-NAME.toit).
set -euo pipefail
P=/home/flo/work/opentoit-sandbox-artifacts/ec618/qemu/progs
cd "$P"
{
  cat <<'EOF'
// Copyright (C) 2026 Toit contributors.
// The benchmarks of suite.toit as a library, for one program per benchmark.
import encoding.json
import .richards as richards
import .deltablue as deltablue
import .pystone as pystone

run-bench name/string -> any:
  if name == "richards":
    richards.run-richards
    return 0
  if name == "deltablue":
    deltablue.chain-test 50
    deltablue.projection-test 50
    return 0
  if name == "pystone":
    pystone.pystones --loops=2000
    return 0
  if name == "json": return json-bench
  if name == "map-set": return map-set-bench
  if name == "strings": return string-bench
  if name == "gc-stress": return gc-stress
  if name == "empty": return 0
  throw "unknown $name"

EOF
  awk '/^json-bench -> int:/,0' suite.toit
} > benches.toit
for b in empty richards deltablue pystone json map-set strings gc-stress; do
  printf 'import .benches\nmain:\n  print "BENCH %s $(run-bench "%s")"\n' "$b" "$b" > "bench-$b.toit"
done
ls bench-*.toit
