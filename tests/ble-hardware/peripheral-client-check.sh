#!/bin/bash
# A peripheral that reads its central's database, against BlueZ: the original
# ESP32 runs peripheral-client.toit beside a Just Works provider; bluetoothd
# on the Edimax dongle (hci index resolved by MAC) connects, discovers the
# board, and serves its own GAP database, which the board reads over the same
# link. The board then asks BlueZ to pair with a Security Request.
set -uo pipefail
cd "$(dirname "$0")/../.."
T=build/host/sdk/bin/toit
port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
index=$(btmgmt info | awk '/^hci/{h=$1} /addr 08:BE:AC:2A:DA:C2/{sub(":","",h); print substr(h,4)}')
[ -n "$index" ] || { echo "adapter 08:BE:AC:2A:DA:C2 not found"; exit 2; }
C=build/ble-peripheral-client; mkdir -p "$C"
$T compile -s -o "$C/provider.snapshot" tests/ble-hardware/pairing-gatt-provider.toit || exit 1
$T compile -s -o "$C/app.snapshot" tests/ble-hardware/peripheral-client.toit || exit 1
cp build/esp32-ble-host/firmware.envelope "$C/app.envelope"
$T tool firmware -e "$C/app.envelope" container install ble-provider "$C/provider.snapshot" || exit 1
$T tool firmware -e "$C/app.envelope" container install app "$C/app.snapshot" || exit 1
$T tool firmware -e "$C/app.envelope" flash --port "$port" --partition empty:nvs=65536 2>&1 | tail -1
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  sudo -n btmgmt --index "$index" power off > /dev/null 2>&1 || true
}
trap cleanup EXIT
timeout -s INT -k 5s 90s jag monitor --port "$port" --force-plain > "$C/board.log" 2>&1 &
pids+=($!)
for i in $(seq 1 300); do grep -qa "address:" "$C/board.log" && break; sleep 0.1; done
address=$(grep -ao "address: [0-9a-f:]*" "$C/board.log" | head -1 | cut -d' ' -f2 | tr a-f A-F)
sudo -n btmgmt --index "$index" power on > /dev/null || exit 2
controller=08:BE:AC:2A:DA:C2
# A bond BlueZ kept from an earlier campaign would make it encrypt with a key
# the freshly flashed board no longer has (authentication failure).
{ echo "agent NoInputNoOutput"; echo "default-agent"; echo "select $controller"; echo "remove $address"; echo "scan le"; sleep 8; echo "scan off"; echo "connect $address"; sleep 6
  # BlueZ asks its agent to authorize pairing that the peripheral asked for.
  echo "yes"; sleep 8
  echo "disconnect $address"; sleep 2; echo "remove $address"; echo quit; } | bluetoothctl > "$C/bluetoothctl.log" 2>&1
sleep 2
grep -a "Connection successful\|Failed to connect\|ServicesResolved" "$C/bluetoothctl.log" | sed 's/\x1b\[[0-9;]*m//g' | head -5
echo "--- board:"
grep -a "address:\|connected:\|PERIPHERAL_CLIENT\|disconnected:\|EXCEPTION" "$C/board.log" | cut -c1-200
grep -qa "PERIPHERAL_CLIENT security=1" "$C/board.log"
