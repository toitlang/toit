#!/bin/bash
# Controller-based address resolution between two boards. The original ESP32
# runs examples/ble/v2-peripheral.toit beside
# private-gatt-provider.toit and advertises from resolvable private
# addresses. ESP32-S3 Board1 loads the peripheral's identity and IRK into its
# controller's resolving list (private-resolving-provider.toit) and runs
# private-central.toit: it finds the peripheral by identity and connects by
# identity twice, the second time without scanning. (The rig's Realtek
# dongles lack link-layer privacy.)
set -uo pipefail
cd "$(dirname "$0")/../.."
T=build/host/sdk/bin/toit
peripheral_port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
central_port=/dev/serial/by-id/usb-1a86_USB_Single_Serial_544C020917-if00
C=build/ble-private-resolve; mkdir -p "$C"
$T compile -s -o "$C/peripheral-provider.snapshot" tests/ble-hardware/private-gatt-provider.toit || exit 1
$T compile -s -o "$C/peripheral.snapshot" examples/ble/v2-peripheral.toit || exit 1
$T compile -s -o "$C/central-provider.snapshot" tests/ble-hardware/private-resolving-provider.toit || exit 1
$T compile -s -o "$C/central.snapshot" tests/ble-hardware/private-central.toit || exit 1
cp build/esp32-ble-host/firmware.envelope "$C/peripheral.envelope"
cp build/esp32s3-ble-host/firmware.envelope "$C/central.envelope"
$T tool firmware -e "$C/peripheral.envelope" container install ble-provider "$C/peripheral-provider.snapshot" || exit 1
$T tool firmware -e "$C/peripheral.envelope" container install next "$C/peripheral.snapshot" || exit 1
$T tool firmware -e "$C/central.envelope" container install ble-provider "$C/central-provider.snapshot" || exit 1
$T tool firmware -e "$C/central.envelope" container install central "$C/central.snapshot" || exit 1
$T tool firmware -e "$C/peripheral.envelope" flash --port "$peripheral_port" --partition empty:nvs=65536 2>&1 | tail -1
pids=()
cleanup() { for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
timeout -s INT -k 5s 150s jag monitor --port "$peripheral_port" --force-plain > "$C/peripheral.log" 2>&1 &
pids+=($!)
for i in $(seq 1 300); do grep -qa "address:" "$C/peripheral.log" && break; sleep 0.1; done
grep -qa "address: 08:3a:f2:23:4d:aa" "$C/peripheral.log" || { echo "unexpected peripheral identity"; grep -a "address:" "$C/peripheral.log"; exit 2; }
$T tool firmware -e "$C/central.envelope" flash --port "$central_port" --partition empty:nvs=65536 2>&1 | tail -1
timeout -s INT -k 5s 90s jag monitor --port "$central_port" --force-plain > "$C/central.log" 2>&1 &
pids+=($!)
for i in $(seq 1 900); do grep -qa "PRIVATE_CENTRAL COMPLETE\|EXCEPTION\|error" "$C/central.log" && break; sleep 0.1; done
sleep 2
grep -a "PRIVATE_CENTRAL\|EXCEPTION\|error\|^  [0-9]*:" "$C/central.log" | cut -c1-200
echo "--- peripheral:"
grep -a "address:\|connected:\|disconnected:\|EXCEPTION" "$C/peripheral.log" | cut -c1-200
grep -qa "PRIVATE_CENTRAL COMPLETE" "$C/central.log"
