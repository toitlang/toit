#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: board 2 after its f1 soak: the final build's install
# profile (traced) and verification time (time-only), a 30-minute traced
# soak (the failed verifier requests with the largest free block).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
bash scripts/hwrun.sh b2 esp32-f2trace-fin2-install b2-f2trace-fin2-install 900 --test-partitions --wifi > /dev/null 2>&1
echo "trace install: $(grep -a -c 'install-trace\] heap' logs/b2-f2trace-fin2-install.txt) traced verifications"
bash scripts/hwrun.sh b2 esp32-f2time-fin-install b2-f2time-fin-install 900 --test-partitions --wifi > /dev/null 2>&1
echo "time install: $(grep -a -c 'install-trace\] acc' logs/b2-f2time-fin-install.txt) accepted"
bash scripts/soak.sh b2 esp32-f2trace-fin2-soakd b2-f2trace-fin2-soak 1800 > logs/soak-b2-f2trace.summary 2>&1
echo "traced soak: $(grep -a -c SOAK-INSTALL logs/b2-f2trace-fin2-soak.txt) ok, $(grep -a -c 'install .* failed' logs/b2-f2trace-fin2-soak.txt) failed"
