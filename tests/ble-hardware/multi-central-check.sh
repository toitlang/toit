#!/bin/bash
set -uo pipefail
cd /home/flo/work/opentoit-ble
C=build/ble-compat-001; T=build/host/sdk/bin/toit
port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
index=$(btmgmt info | awk '/^hci/{h=$1} /addr 08:BE:AC:2A:DA:C2/{sub(":","",h); print substr(h,4)}')
other=$(btmgmt info | awk '/^hci/{h=$1} /addr 8A:88:4B:A3:56:A9/{sub(":","",h); print substr(h,4)}')
echo "dongle=$index observer=$other"
$T compile -s -o $C/provider.snapshot tests/ble-hardware/bench/provider-traced.toit
$T compile -s -o $C/central.snapshot tests/ble-hardware/compat-central.toit
$T compile -s -o $C/heart-rate.snapshot examples/ble/heart_rate.toit
cp build/esp32-ble-current/firmware.envelope $C/app.envelope
$T tool firmware -e $C/app.envelope container install ble-provider $C/provider.snapshot
$T tool firmware -e $C/app.envelope container install heart-rate $C/heart-rate.snapshot
$T tool firmware -e $C/app.envelope flash --port $port --partition empty:nvs=65536 2>&1 | tail -1
pids=()
cleanup() { for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; sudo -n /usr/bin/btmgmt --index "$index" power on >/dev/null 2>&1 || true; }
trap cleanup EXIT
timeout -s INT -k 5s 90s jag monitor --port $port --force-plain > $C/multi-board.log 2>&1 & pids+=($!)
sleep 8
sudo -n /usr/bin/btmgmt --index "$index" power off >/dev/null
timeout -s INT -k 5s 60s build/host/sdk/lib/toit/bin/toit.run $C/central.snapshot "$index" connect 00aa4d23f23a08 hold > $C/multi-central.log 2>&1 & pids+=($!)
for i in $(seq 1 100); do grep -aq "COMPAT holding" $C/multi-central.log && break; sleep 0.1; done
wait ${pids[1]}; echo "central-exit=$?"
grep -a "COMPAT" $C/multi-central.log | tail -3
sleep 3
grep -a "Heart rate" $C/multi-board.log | head -2
echo "--- HCI on the board: connection complete, then advertising enabled again?"
grep -a "^HCI" $C/multi-board.log | grep -n "043e13\|010a200101\|010a200100\|040504" | head -12 | cut -c1-80
