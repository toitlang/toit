#!/bin/bash
# Usage: run.sh toit|nimble [cycles]
set -uo pipefail
cd /home/flo/work/opentoit-ble
variant=$1; cycles=${2:-10}
C=build/ble-bench-001; T=build/host/sdk/bin/toit
# BENCH_BOARD=s3 runs on ESP32-S3 Board1 (2M PHY capable) instead of the original ESP32.
if [ "${BENCH_BOARD:-esp32}" = s3 ]; then
  port=/dev/serial/by-id/usb-1a86_USB_Single_Serial_544C020917-if00
  peer=f412fac150fe
  firmware=build/esp32s3-ble-host/firmware.envelope
else
  port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
  peer=083af2234daa
  firmware=build/esp32-ble-host/firmware.envelope
fi
index=$(btmgmt info | awk '/^hci/{h=$1} /addr 08:BE:AC:2A:DA:C2/{sub(":","",h); print substr(h,4)}')
[ -n "$index" ] || { echo "adapter not found"; exit 2; }
mkdir -p "$C/$variant"
if [ "$variant" = toit ]; then
  cp "$firmware" "$C/toit.envelope"
  $T compile -s -o "$C/provider.snapshot" tests/ble-hardware/bench/provider.toit
  $T compile -s -o "$C/app.snapshot" tests/ble-hardware/bench/app.toit
  $T tool firmware -e "$C/toit.envelope" container install ble-provider "$C/provider.snapshot"
  $T tool firmware -e "$C/toit.envelope" container install bench "$C/app.snapshot"
  envelope="$C/toit.envelope"
elif [ "$variant" = direct ]; then
  cp "$firmware" "$C/direct.envelope"
  $T compile -s -o "$C/direct.snapshot" tests/ble-hardware/bench/direct.toit
  $T tool firmware -e "$C/direct.envelope" container install bench "$C/direct.snapshot"
  envelope="$C/direct.envelope"
else
  cp build/esp32-ble-nimble-regression/firmware.envelope "$C/nimble.envelope"
  $T compile -s -o "$C/nimble.snapshot" tests/ble-hardware/bench/nimble.toit
  $T tool firmware -e "$C/nimble.envelope" container install bench "$C/nimble.snapshot"
  envelope="$C/nimble.envelope"
fi
$T compile -s -o "$C/central.snapshot" tests/ble-hardware/bench/central.toit
$T tool firmware -e "$envelope" flash --port "$port" --partition empty:nvs=65536 2>&1 | tail -1
pids=()
cleanup() { for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; sudo -n /usr/bin/btmgmt --index "$index" power on >/dev/null 2>&1 || true; }
trap cleanup EXIT
timeout -s INT -k 5s 600s jag monitor --port "$port" --force-plain > "$C/$variant/board.log" 2>&1 & pids+=($!)
for i in $(seq 1 300); do grep -aq "phase=advertising" "$C/$variant/board.log" && break; sleep 0.1; done
sleep 2
sudo -n /usr/bin/btmgmt --index "$index" power off >/dev/null
timeout -s INT -k 5s 500s build/host/sdk/lib/toit/bin/toit.run "$C/central.snapshot" "$index" "$peer" "$cycles" > "$C/$variant/central.log" 2>&1
echo "central-exit=$?"
sleep 3
grep -a "BENCH" "$C/$variant/central.log" | cut -c1-160
grep -a "BENCH\|EXCEPTION" "$C/$variant/board.log" | grep -v periodic | cut -c1-160
echo "--- periodic samples: $(grep -ac periodic "$C/$variant/board.log")"
