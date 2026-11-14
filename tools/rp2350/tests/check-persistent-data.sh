#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

set -euo pipefail

elf=${1:?usage: check-persistent-data.sh TOIT-RP2350.ELF}
objdump=${OBJDUMP:-arm-none-eabi-objdump}
nm=${NM:-arm-none-eabi-nm}

for tool in "$objdump" "$nm"; do
  command -v "$tool" >/dev/null || {
    echo "Missing check prerequisite: $tool" >&2
    exit 2
  }
done

section=$(
  "$objdump" -h "$elf" |
    awk '$2 == ".persistent_data" { print $3, $4 }'
)
if [[ -z "$section" ]]; then
  echo 'Missing .persistent_data section.' >&2
  exit 1
fi
read -r size_hex address_hex <<<"$section"

size=$((16#$size_hex))
address=$((16#$address_hex))
end=$((address + size))
if (( size < 0x1010 )); then
  printf '.persistent_data is too small: 0x%x (minimum 0x1010)\n' "$size" >&2
  exit 1
fi
# RP2350 SRAM bank 0 is the bottom 256 KiB of SRAM.
if (( address < 0x20000000 || end > 0x20040000 )); then
  printf '.persistent_data is outside SRAM bank 0: 0x%x..0x%x\n' \
    "$address" "$end" >&2
  exit 1
fi

symbols=$("$nm" -C -S "$elf")
check_symbol() {
  local name=$1 pattern=$2 expected_size=$3
  local matches line symbol_address_hex symbol_size_hex symbol_type symbol_name
  matches=$(grep -E "$pattern" <<<"$symbols" || true)
  if [[ $(grep -Ec . <<<"$matches") != 1 ]]; then
    echo "Expected exactly one retained symbol for $name." >&2
    exit 1
  fi
  line=$matches
  read -r symbol_address_hex symbol_size_hex symbol_type symbol_name <<<"$line"
  local symbol_address=$((16#$symbol_address_hex))
  local symbol_size=$((16#$symbol_size_hex))
  local symbol_end=$((symbol_address + symbol_size))
  if (( symbol_size != expected_size )); then
    printf 'Unexpected %s size: 0x%x (expected 0x%x)\n' \
      "$name" "$symbol_size" "$expected_size" >&2
    exit 1
  fi
  if (( symbol_address < address || symbol_end > end )); then
    printf '%s is outside .persistent_data: 0x%x..0x%x\n' \
      "$name" "$symbol_address" "$symbol_end" >&2
    exit 1
  fi
}

check_symbol real-time-offset \
  '^[0-9a-fA-F]+ [0-9a-fA-F]+ [Bb] toit::real_time_offset$' 0x8
check_symbol awake-time-offset \
  '^[0-9a-fA-F]+ [0-9a-fA-F]+ [Bb] toit::awake_time_at_sleep$' 0x8
check_symbol rtc-memory \
  '^[0-9a-fA-F]+ [0-9a-fA-F]+ [Bb] .*::rtc_memory$' 0x1000

printf 'RP2350 persistent data: PASS (0x%x bytes at 0x%x, SRAM bank 0)\n' \
  "$size" "$address"
