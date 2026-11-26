#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The final firmware gates: ESP32 and C6 in f1 and f2 (the classic ESP32's
# f2 with ESP_WIFI_RX_IRAM_OPT off, as TOIT_VERIFIED_CORE_LOOP_IN_IRAM
# needs), the QEMU suite f1 against f2, the flash budget with Jaguar and
# the QEMU benchmarks. Never flashes. Output: logs/final-fw.txt
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
cd "$A" || exit 1
O=logs/final-fw.txt
: > $O
bash scripts/fw-all.sh esp32 final3 f1 f2nowifi >> $O 2>&1
bash scripts/fw-all.sh esp32c6 final3 f1 f2 >> $O 2>&1
rm -rf bins/esp32-f2 && cp -r bins/esp32-f2nowifi bins/esp32-f2
bash scripts/loopsize.sh f2 >> $O 2>&1
grep -E "^\.iram0\.text " bins/esp32-f2/sections.txt bins/esp32c6-f2/sections.txt >> $O
bash scripts/make-untrusted.sh $A/qemu/untrusted > logs/untrusted-final3.log 2>&1
bash scripts/suite-all.sh final3 f1 f2 > logs/suite-final3.txt 2>&1
tail -3 logs/suite-final3.txt >> $O
diff /home/flo/work/opentoit-sandbox-artifacts/compact-methods/dev/qemu/run-f2-cm/suite.txt qemu/run-f2-final3/suite.txt >> $O 2>&1 && echo "f2 suite identical to compact-methods" >> $O
diff /home/flo/work/opentoit-sandbox-artifacts/compact-methods/dev/qemu/run-f1-cm/suite.txt qemu/run-f1-final3/suite.txt >> $O 2>&1 && echo "f1 suite identical to compact-methods" >> $O
bash scripts/jag-all.sh >> $O 2>&1
bash scripts/bench-qemu.sh f2 final3 >> $O 2>&1
echo done >> $O
