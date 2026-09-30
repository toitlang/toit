#!/bin/bash
# The application API on hardware: the controller-only board runs
# examples/ble/v2-peripheral.toit on the system container's BLE provider, the
# Edimax dongle runs next-central.toit. NEXT_BOARD=s3 uses ESP32-S3 Board1
# (2M PHY) instead of the original ESP32.
# Usage: tests/ble-hardware/next-check.sh [phy to request]
set -uo pipefail
cd "$(dirname "$0")/../.."
T=build/host/sdk/bin/toit
if [ "${NEXT_BOARD:-esp32}" = s3 ]; then
  port=/dev/serial/by-id/usb-1a86_USB_Single_Serial_544C020917-if00
  firmware=build/esp32s3/firmware.envelope
else
  port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
  firmware=build/esp32/firmware.envelope
fi
index=$(btmgmt info | awk '/^hci/{h=$1} /addr 08:BE:AC:2A:DA:C2/{sub(":","",h); print substr(h,4)}')
[ -n "$index" ] || { echo "adapter 08:BE:AC:2A:DA:C2 not found"; exit 2; }
C=build/ble-next-001/${NEXT_BOARD:-esp32}; mkdir -p "$C"
$T compile -s -o "$C/peripheral.snapshot" examples/ble/v2-peripheral.toit || exit 1
$T compile -s -o "$C/central.snapshot" tests/ble-hardware/next-central.toit || exit 1
cp "$firmware" "$C/app.envelope"
$T tool firmware -e "$C/app.envelope" container install next "$C/peripheral.snapshot" || exit 1
$T tool firmware -e "$C/app.envelope" flash --port "$port" --partition empty:nvs=65536 2>&1 | tail -1
pids=()
cleanup() { for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
timeout -s INT -k 5s 120s jag monitor --port "$port" --force-plain > "$C/board.log" 2>&1 &
pids+=($!)
for i in $(seq 1 300); do grep -qa "address:" "$C/board.log" && break; sleep 0.1; done
address=$(grep -ao "address: [0-9a-f:]*" "$C/board.log" | head -1 | cut -d' ' -f2)
timeout -s INT -k 5s 60s build/host/sdk/lib/toit/bin/toit.run "$C/central.snapshot" "$index" "$address" ${1:-} > "$C/central.log" 2>&1
echo "central-exit=$?"
sleep 3
grep -a "NEXT_CENTRAL\|EXCEPTION\|error" "$C/central.log" | cut -c1-200
echo "--- board:"
grep -a "address:\|tx power\|link power\|connected:\|parameters\|link:\|  interval\|reset the\|disconnected:\|EXCEPTION" "$C/board.log" | cut -c1-200
