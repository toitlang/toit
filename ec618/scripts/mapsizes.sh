#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Attributes the bytes of the EC618 slot link (toit-slot-a.map) to components,
# per output section (.vm_a: flash; .vm_dram_data / .vm_dram_zi: RAM).
# Usage: mapsizes.sh MAP
set -euo pipefail
awk '
  function group(file) {
    if (file ~ /libtoit_rust/) return "rust (core, primitives, verifier)"
    if (file ~ /interpreter_run\.cc|method_entries\.cc/) return "c++ interpreter (format 1)"
    if (file ~ /interpreter_v2\.cc|verifier_v2\.cc|v2_method_table\.cc/) return "c++ format-2 glue"
    if (file ~ /libtoit_vm/) return "vm (rest)"
    if (file ~ /libmbed|everest|p256/) return "mbedtls"
    if (file ~ /libgcc|libc_nano|libc\.a|libm|libstdc|libsupc|libnosys/) return "toolchain libs"
    return "other"
  }
  function hex(s,   v, k) {
    sub(/^0x/, "", s); v = 0
    for (k = 1; k <= length(s); k++) v = v * 16 + index("0123456789abcdef", tolower(substr(s, k, 1))) - 1
    return v
  }
  /^Linker script and memory map/ { inmap = 1; next }
  !inmap { next }
  /^\.[A-Za-z_]/ { out = $1; next }
  /^[A-Za-z]/ { out = ""; next }
  out == "" { next }
  {
    # Input section lines: [name] 0xADDR 0xSIZE file
    n = NF
    if (n >= 3 && $(n-2) ~ /^0x/ && $(n-1) ~ /^0x/ && $n !~ /^0x/) {
      size = hex($(n-1))
      if (size > 0 && $1 != "*fill*") sum[out SUBSEP group($n)] += size
    } else if ($1 == "*fill*" && n >= 3) {
      sum[out SUBSEP "padding"] += hex($3)
    }
  }
  END {
    for (k in sum) { split(k, p, SUBSEP); printf "%-16s %-36s %9d\n", p[1], p[2], sum[k] }
  }' "$1" | sort
