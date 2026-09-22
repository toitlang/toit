#!/bin/bash
# Usage: run-phase.sh pair|resume
set -uo pipefail
cd /home/flo/work/opentoit-ble
phase=$1
C=build/ble-resume-features-001/$phase
mkdir -p "$C"
port=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_7eb10aca7cfbea11919ff4375fbcde76-if00-port0
index=$(btmgmt info | awk '/^hci/{h=$1} /addr 08:BE:AC:2A:DA:C2/{sub(":","",h); print substr(h,4)}')
[ -n "$index" ] || { echo "adapter 08:BE:AC:2A:DA:C2 not found"; exit 2; }
flag=--pairing; [ "$phase" = resume ] && flag="--resume-bond --observe-resume-agent"
pids=()
cleanup() { for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
timeout -s TERM -k 5s 60s build/host/sdk/lib/toit/bin/toit.run build/ble-resume-features-001/observer.snapshot "$index" 08:BE:AC:2A:DA:C2 C8:3A:F2:23:31:51 2 > "$C/observer.log" 2>&1 &
pids+=($!)
for i in $(seq 1 100); do grep -q "MGMT_OBSERVER READY" "$C/observer.log" && break; sleep 0.1; done
timeout -s TERM -k 5s 120s /tmp/ble-bluez-dbus-venv/bin/python tests/ble-interop/bluez-gatt-server.py --adapter "hci$index" --address 08:BE:AC:2A:DA:C2 --peer-address C8:3A:F2:23:31:51 $flag > "$C/reference.log" 2>&1 &
ref=$!; pids+=($ref)
for i in $(seq 1 150); do grep -q '"event": "ready"' "$C/reference.log" && break; kill -0 $ref 2>/dev/null || break; sleep 0.1; done
grep -q '"event": "ready"' "$C/reference.log" || { echo "reference did not start"; cat "$C/reference.log"; exit 1; }
timeout -s INT -k 5s 150s jag monitor --port "$port" --force-plain --envelope build/ble-resume-features-001/application.envelope > "$C/board.log" 2>&1 &
mon=$!; pids+=($mon)
wait $ref; echo "reference-exit=$?" | tee "$C/reference.exit"
for i in $(seq 1 30); do grep -q "entering deep sleep" "$C/board.log" && break; sleep 1; done
kill -INT $mon 2>/dev/null || true; wait $mon 2>/dev/null || true
grep -E "RESUME_FEATURES|CENTRAL_FRESH|CENTRAL_BOND|CENTRAL_RADIO|SERVICE_CENTRAL|EXCEPTION|error|deep sleep" "$C/board.log" | cut -c1-160
echo "--- reference events:"; grep -o '"event": "[a-z_]*"' "$C/reference.log" | sort | uniq -c
echo "--- observer:"; grep -v "^$" "$C/observer.log" | tail -8
