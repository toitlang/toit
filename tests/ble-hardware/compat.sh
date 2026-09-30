#!/bin/bash
set -uo pipefail
cd /home/flo/work/opentoit-ble
C=build/ble-compat-001; T=build/host/sdk/bin/toit; mkdir -p $C
port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
index=$(btmgmt info | awk '/^hci/{h=$1} /addr 08:BE:AC:2A:DA:C2/{sub(":","",h); print substr(h,4)}')
$T compile -s -o $C/heart-rate.snapshot examples/ble/heart_rate.toit
$T compile -s -o $C/central.snapshot tests/ble-hardware/compat-central.toit
cp build/esp32/firmware.envelope $C/app.envelope
$T tool firmware -e $C/app.envelope container install heart-rate $C/heart-rate.snapshot
$T tool firmware -e $C/app.envelope flash --port $port --partition empty:nvs=65536 2>&1 | tail -1
pids=()
cleanup() { for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; sudo -n /usr/bin/btmgmt --index "$index" power on >/dev/null 2>&1 || true; }
trap cleanup EXIT
timeout -s INT -k 5s 200s jag monitor --port $port --force-plain > $C/board.log 2>&1 & pids+=($!)
sleep 8
sudo -n /usr/bin/btmgmt --index "$index" power off >/dev/null
timeout -s INT -k 5s 60s build/host/sdk/lib/toit/bin/toit.run $C/central.snapshot "$index" scan > $C/central.log 2>&1
echo "scan-exit=$?"
identifier=$(grep -ao "identifier=[0-9a-f]*" $C/central.log | head -1 | cut -d= -f2)
sleep 1
sudo -n /usr/bin/btmgmt --index "$index" power off >/dev/null
sleep 1
timeout -s INT -k 5s 60s build/host/sdk/lib/toit/bin/toit.run $C/central.snapshot "$index" connect "$identifier" >> $C/central.log 2>&1
echo "connect-exit=$?"
sleep 2
grep -a "COMPAT\|EXCEPTION" $C/central.log | cut -c1-160
grep -a "Heart rate\|EXCEPTION\|BENCH provider phase" $C/board.log | grep -v periodic | head -12 | cut -c1-160
