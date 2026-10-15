#!/bin/bash
# Runs the hardware campaigns and checks of docs/ble/hardware.md in sequence
# and prints one line per step. Intended for a cron job on the rig host;
# every step leaves its logs under build/.
#
# Usage: tests/ble-hardware/nightly.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
summary=()
run() { local name=$1; shift; if "$@" > "build/nightly-$name.log" 2>&1; then summary+=("$name: pass"); else summary+=("$name: FAIL (build/nightly-$name.log)"); fi; }
getcap build/host/sdk/lib/toit/bin/toit.run | grep -q cap_net_admin || echo "warning: toit.run lacks cap_net_admin; Linux steps will fail"
T=build/host/sdk/bin/toit
ESP32=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
S3=/dev/serial/by-id/usb-1a86_USB_Single_Serial_544C020917-if00
B1=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_06fbaa46a6e3ea1198b5157c994a5d01-if00-port0
B2=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_cebffb0133faea11a7175a185fbcde76-if00-port0
flash() { $T tool firmware -e "$1" flash --port "$2" --partition empty:nvs=65536 > /dev/null 2>&1; }
# Each campaign gets its own images; the boards may hold another check's image.
flash build/ble-resume-features-003/application.envelope $ESP32
busctl --system call org.bluez /org/bluez/hci0 org.bluez.Adapter1 RemoveDevice o /org/bluez/hci0/dev_C8_3A_F2_23_31_51 > /dev/null 2>&1 || true
run "resume-pair" build/ble-resume-features-003/run-phase.sh pair
run "resume-resume" build/ble-resume-features-003/run-phase.sh resume
flash build/ble-mic-003/peer.envelope $B1; flash build/ble-mic-003/peer.envelope $B2; flash build/ble-mic-003/central.envelope $S3
sleep 200   # freshly flashed boards must reach deep sleep before the monitors reset them in order
run "revocation" build/ble-mic-003/run.sh "nightly-$(date +%Y%m%d)"
run "bench-toit" build/ble-bench-001/run.sh toit 5
run "bench-direct" build/ble-bench-001/run.sh direct 5
run "compat" tests/ble-hardware/compat.sh
run "next" tests/ble-hardware/next-check.sh
run "next-s3" env NEXT_BOARD=s3 tests/ble-hardware/next-check.sh 2
run "private-resolve" tests/ble-hardware/private-resolve.sh
run "peripheral-client" tests/ble-hardware/peripheral-client-check.sh
printf '%s\n' "${summary[@]}"
# Pass criteria per step (grep the logs): resume phases print CENTRAL_FRESH COMPLETE
# with resumed=true in the resume phase; revocation prints REVOKE_TWO COMPLETE and
# both peers REVOKE_AUTH COMPLETE; bench prints central-exit=0; compat prints
# COMPAT COMPLETE and the board Heart rate app received data.
for f in resume-pair resume-resume revocation bench-toit bench-direct compat next next-s3 private-resolve peripheral-client; do
  printf '%-14s ' "$f"; grep -aoh "CENTRAL_FRESH COMPLETE[^ ]*\|REVOKE_TWO COMPLETE\|REVOKE_AUTH COMPLETE peer=[01]\|central-exit=[0-9]\|COMPAT COMPLETE\|Heart rate app received data\|LEGACY_BOND COMPLETE resumed=[a-z]*\|NEXT_CENTRAL COMPLETE\|PRIVATE_CENTRAL COMPLETE\|PERIPHERAL_CLIENT security=[0-9]" "build/nightly-$f.log" 2>/dev/null | sort | uniq -c | tr '\n' ';'; echo
done
