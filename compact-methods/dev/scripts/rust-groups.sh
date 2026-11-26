#!/usr/bin/env bash
# Groups the linked Rust sections of a firmware map (mapsyms.sh output of the
# toit_rust object) by component: run loop, core cold paths, primitives,
# verifier (toit_spec + toit_vmverify), alloc/core, the rest.
# Usage: rust-groups.sh MAP
set -euo pipefail
D=$(dirname "$0")
bash "$D/mapsyms.sh" "$1" 'toit_rust-' | awk '{print $1, $2}' |
  sed -E 's/ \.(text|literal|rodata|data|bss|sdata|sbss)\./ \1 /' | c++filt |
  awk '
    { size = $1; kind = $2; $1 = ""; $2 = ""; name = $0 }
    name ~ /step::run_loop/ { g = "core: run_loop" }
    name !~ /step::run_loop/ && name ~ /toit_verified_core.*::prims::/ { g = "core: primitives (prims::)" }
    name ~ /toit_verified_core/ && name !~ /prims::/ && name !~ /run_loop/ { g = "core: cold paths, r* helpers" }
    name ~ /^ *unlikely\._R.*18toit_verified_core/ { g = "core: cold paths, r* helpers" }
    name ~ /toit_spec/ { g = "verifier: toit_spec" }
    name ~ /toit_vmverify/ { g = "verifier: vmverify glue" }
    name ~ /(^| |<)(alloc|core)\[/ { g = "core/alloc library" }
    name ~ /toit_v2_|toit_vmverify_/ && name !~ /\[/ { g = "C entry points" }
    g == "" { g = "other: " kind }
    { tot[g] += size; all += size; if (g ~ /^other/) ex[g] = ex[g] " " name }
    { g = "" }
    END {
      for (k in tot) printf "%8d %s\n", tot[k], k
      printf "%8d total\n", all
    }' | sort -n
