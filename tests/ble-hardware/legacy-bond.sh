#!/bin/bash
# LE legacy pairing against a NimBLE peer: flashes ESP32 Board2 with the
# default (NimBLE) firmware and fixtures/nimble-legacy-bond-peer.toit, then
# runs legacy-bond-central.toit on the Edimax dongle twice: pair (stores the
# bond record) and resume (encrypts with the distributed key, no pairing).
# Usage: tests/ble-hardware/legacy-bond.sh [nimble firmware envelope]
set -uo pipefail
cd "$(dirname "$0")/../.."
T=build/host/sdk/bin/toit
firmware=${1:-build/esp32/firmware.envelope}
port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_cebffb0133faea11a7175a185fbcde76-if00-port0
index=$(btmgmt info | awk '/^hci/{h=$1} /addr 08:BE:AC:2A:DA:C2/{sub(":","",h); print substr(h,4)}')
[ -n "$index" ] || { echo "adapter 08:BE:AC:2A:DA:C2 not found"; exit 2; }
C=build/ble-legacy-bond-001; mkdir -p "$C"; rm -f "$C/record"
cp "$firmware" "$C/peer.envelope"
$T compile -s -o "$C/peer.snapshot" tests/ble-hardware/fixtures/nimble-legacy-bond-peer.toit || exit 1
$T tool firmware -e "$C/peer.envelope" container install peer "$C/peer.snapshot" || exit 1
$T compile -s -o "$C/central.snapshot" tests/ble-hardware/legacy-bond-central.toit || exit 1
$T tool firmware -e "$C/peer.envelope" flash --port "$port" --partition empty:nvs=65536 2>&1 | tail -1
pids=()
cleanup() { for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; sudo -n /usr/bin/btmgmt --index "$index" power on >/dev/null 2>&1 || true; }
trap cleanup EXIT
timeout -s INT -k 5s 200s jag monitor --port "$port" --force-plain --envelope "$C/peer.envelope" > "$C/board.log" 2>&1 &
pids+=($!)
for i in $(seq 1 300); do grep -q "NIMBLE_LEGACY READY" "$C/board.log" && break; sleep 0.1; done
grep -q "NIMBLE_LEGACY READY" "$C/board.log" || { echo "peer did not start"; tail -5 "$C/board.log"; exit 1; }
for phase in pair resume; do
  # bluetoothd re-powers the dongle whenever a user channel closes.
  sudo -n /usr/bin/btmgmt --index "$index" power off >/dev/null
  timeout -s INT -k 5s 60s build/host/sdk/lib/toit/bin/toit.run "$C/central.snapshot" "$index" "$phase" "$C/record" > "$C/$phase.log" 2>&1
  echo "$phase-exit=$?"; grep -a "LEGACY_BOND\|EXCEPTION\|error" "$C/$phase.log" | cut -c1-160
  sleep 3
done
sleep 2; echo "--- board:"; grep -a "NIMBLE_LEGACY\|EXCEPTION\|error" "$C/board.log" | cut -c1-160
