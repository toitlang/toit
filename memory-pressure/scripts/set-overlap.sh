#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: in the ESP32 flash cache (two-way, 16 KB per way, 32-byte
# lines), the bytes of cache-set range shared by the allocator's flash
# functions (heap_caps_*, esp_heap_*) and the verifier's hot functions
# (the 44 of the hot list's group B head; x_post_into and
# toit_vmverify_verify reported separately).
# Usage: set-overlap.sh BIN-NAME...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
NM=$HOME/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
HOT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f/build/tmp/bhot.txt
for b in "$@"; do
  "$NM" -S "$A/bins/$b/toit.elf" | awk -v hotfile="$HOT" -v name="$b" '
    BEGIN { while ((getline l < hotfile) > 0) { split(l, f, "\t"); g = f[1]; sub(/^\*/, "", g); hot[g] = 1 } }
    NF >= 4 && ($3 ~ /^[tT]$/) {
      a = strtonum("0x" $1); s = strtonum("0x" $2); n = $4
      if (a < 0x400d0000 || a >= 0x40400000) next
      k = ""
      if (n ~ /^(heap_caps_(malloc|free|aligned_alloc|realloc|match)|esp_heap_adjust)/) k = "heap"
      else if (n ~ /x_post_into$/) k = "post"
      else if (n == "toit_vmverify_verify") k = "verify"
      else for (g in hot) if (index(n, g) > 0) { k = "hot"; break }
      if (k == "") next
      for (x = int(a / 32); x <= int((a + s - 1) / 32); x++) { set = x % 512; mark[k, set] = 1 }
    }
    END {
      split("hot post verify", ks, " ")
      printf "%s:", name
      for (i = 1; i <= 3; i++) { c = 0; for (s = 0; s < 512; s++) if (mark["heap", s] && mark[ks[i], s]) c++; printf " heap/%s %d lines", ks[i], c }
      h = 0; for (s = 0; s < 512; s++) if (mark["heap", s]) h++
      printf " (heap %d lines)\n", h
    }'
done
