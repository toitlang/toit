#!/usr/bin/env bash
# Disassembles step::run_loop of an ESP32 firmware ELF.
# Usage: runloop-dis.sh ELF OUT
OBJ=$HOME/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-objdump
NM=$HOME/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
read -r addr size _ name < <("$NM" -S "$1" | grep "4step8run_loop$")
start=$((16#$addr)); end=$((start + 16#$size))
"$OBJ" -d --no-show-raw-insn --start-address=$start --stop-address=$end "$1" > "$2"
wc -l "$2"
