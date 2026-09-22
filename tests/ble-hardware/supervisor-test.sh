#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Linux-only process/lock tests. No management socket or Bluetooth hardware.
set -euo pipefail
supervisor=$(realpath "$1")
work=$(realpath -m "$2")
work=$(mktemp -d "$work.XXXXXX")
printf -v address '02:%02x:%02x:%02x:%02x:%02x' "$((RANDOM & 255))" "$((RANDOM & 255))" "$((RANDOM & 255))" "$((RANDOM & 255))" "$((RANDOM & 255))"
lock="/tmp/toit-hci-${address//:/}.lock"
[[ ! -e "$lock" && ! -L "$lock" ]]
active=
cleanup() {
  if [[ -n "$active" ]]; then
    kill -TERM "$active" 2>/dev/null || true
    wait "$active" 2>/dev/null || true
  fi
  if [[ -d "$lock" && ! -L "$lock" ]]; then rmdir "$lock"; else rm -f "$lock"; fi
}
trap cleanup EXIT
export BLE_TEST_STATE="$work/state" BLE_TEST_EVENTS="$work/events" BLE_TEST_FAULT=
cat > "$work/policy.sh" <<'EOF'
set -eu
printf '%s\n' "$3" >> "$BLE_TEST_EVENTS"
case "$3" in
  state)
    if [ "$BLE_TEST_FAULT" = hang ]; then
      trap '' TERM INT
      echo $$ > "$BLE_TEST_STATE.hung-pid"
      while :; do sleep 60; done
    fi
    if [ "$BLE_TEST_FAULT" = flood ]; then
      while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done
    fi
    if [ "$BLE_TEST_FAULT" = identity ]; then exit 8; fi
    if [ "$BLE_TEST_FAULT" = token ]; then echo unexpected; else cat "$BLE_TEST_STATE"; fi
    ;;
  power-off)
    echo off > "$BLE_TEST_STATE"
    if [ "$BLE_TEST_FAULT" = prepare ]; then exit 9; fi
    echo off
    ;;
  power-on)
    if [ "$BLE_TEST_FAULT" = restore ]; then exit 7; fi
    if [ "$BLE_TEST_FAULT" = restore-wait ]; then
      echo ready > "$BLE_TEST_STATE.restoring"
      while [ ! -f "$BLE_TEST_STATE.release" ]; do sleep 0.01; done
    fi
    echo on > "$BLE_TEST_STATE"
    echo on
    ;;
  *) exit 2 ;;
esac
EOF
reset() {
  echo "${1:-on}" > "$BLE_TEST_STATE"
  : > "$BLE_TEST_EVENTS"
  export BLE_TEST_FAULT=
}
run_expect() {
  local name=$1 expected=$2 actual=0
  shift 2
  "$supervisor" 0 "$address" /bin/sh "$work/policy.sh" -- "$@" > "$work/$name.log" 2>&1 || actual=$?
  [[ $actual == "$expected" ]]
  echo "$name: PASS"
}
reset
run_expect normal 0 /bin/true
[[ $(< "$BLE_TEST_STATE") == on ]]
reset
run_expect child-failure 7 /bin/sh -c 'exit 7'
[[ $(< "$BLE_TEST_STATE") == on ]]
reset
run_expect exec-failure 127 "$work/no-such-command"
[[ $(< "$BLE_TEST_STATE") == on ]]
reset off
run_expect originally-off 0 /bin/true
[[ $(< "$BLE_TEST_STATE") == off ]]
reset
export BLE_TEST_FAULT=prepare
run_expect prepare-failure 125 /bin/sh -c 'touch "$1"' sh "$work/unexpected-child"
[[ $(< "$BLE_TEST_STATE") == on && ! -e "$work/unexpected-child" ]]
reset
export BLE_TEST_FAULT=restore
run_expect restore-failure 125 /bin/sh -c 'exit 7'
[[ $(< "$work/restore-failure.log") == *'child-exit=7 restoration-verified=false'* ]]
reset
export BLE_TEST_FAULT=identity
run_expect identity-failure 125 /bin/true
[[ $(< "$BLE_TEST_EVENTS") == state && $(< "$BLE_TEST_STATE") == on ]]
reset
export BLE_TEST_FAULT=token
run_expect malformed-state 125 /bin/true
[[ $(< "$BLE_TEST_EVENTS") == state ]]
reset
export BLE_TEST_FAULT=hang
started=$SECONDS
run_expect policy-timeout 125 /bin/true
[[ $((SECONDS - started)) -ge 10 && $((SECONDS - started)) -lt 20 ]]
! kill -0 "$(< "$BLE_TEST_STATE.hung-pid")" 2>/dev/null
[[ $(< "$BLE_TEST_EVENTS") == state && $(< "$BLE_TEST_STATE") == on ]]
reset
export BLE_TEST_FAULT=flood
started=$SECONDS
run_expect policy-output-limit 125 /bin/true
[[ $((SECONDS - started)) -lt 5 && $(< "$BLE_TEST_EVENTS") == state ]]

reset
export BLE_TEST_FAULT=restore-wait
"$supervisor" 0 "$address" /bin/sh "$work/policy.sh" -- /bin/true > "$work/interrupted-restoration.log" 2>&1 &
active=$!
for ((attempt=0; attempt<200; attempt++)); do
  if [[ -f "$BLE_TEST_STATE.restoring" ]]; then break; fi
  sleep 0.01
done
[[ -f "$BLE_TEST_STATE.restoring" ]]
before=$(< "$BLE_TEST_EVENTS")
run_expect restoration-contention 125 /bin/true
[[ $(< "$BLE_TEST_EVENTS") == "$before" ]]
kill -TERM "$active"
touch "$BLE_TEST_STATE.release"
code=0
wait "$active" || code=$?
active=
[[ $code == 143 && $(< "$BLE_TEST_STATE") == on ]]
[[ $(< "$work/interrupted-restoration.log") == *'child-exit=0 restoration-verified=true signal=15'* ]]
echo 'interrupted-restoration: PASS'

wait_ready() {
  for ((attempt=0; attempt<200; attempt++)); do
    if [[ -s "$work/child.pid" && -s "$work/grandchild.pid" ]]; then return; fi
    sleep 0.01
  done
  return 1
}
for signal in TERM INT; do
  reset
  rm -f "$work/child.pid" "$work/grandchild.pid"
  "$supervisor" 0 "$address" /bin/sh "$work/policy.sh" -- /bin/sh -c '
    trap "" TERM INT
    echo $$ > "$1/child.pid"
    sleep 60 &
    echo $! > "$1/grandchild.pid"
    wait
  ' sh "$work" > "$work/signal-$signal.log" 2>&1 &
  active=$!
  wait_ready
  if [[ $signal == TERM ]]; then
    before=$(< "$BLE_TEST_EVENTS")
    run_expect contention 125 /bin/true
    [[ $(< "$BLE_TEST_EVENTS") == "$before" ]]
  fi
  kill -"$signal" "$active"
  code=0
  wait "$active" || code=$?
  active=
  expected=143
  if [[ $signal == INT ]]; then expected=130; fi
  [[ $code == "$expected" && $(< "$BLE_TEST_STATE") == on ]]
  ! kill -0 "$(< "$work/child.pid")" 2>/dev/null
  ! kill -0 "$(< "$work/grandchild.pid")" 2>/dev/null
  echo "signal-$signal: PASS"
done
reset
run_expect orphan 0 /bin/sh -c 'sleep 60 & echo $! > "$1"' sh "$work/orphan.pid"
! kill -0 "$(< "$work/orphan.pid")" 2>/dev/null

reset
printf sentinel > "$lock"
run_expect existing-lock 0 /bin/true
[[ $(< "$lock") == sentinel ]]
rm "$lock"
printf untouched > "$work/target"
ln -s "$work/target" "$lock"
reset
run_expect symlink 125 /bin/true
[[ ! -s "$BLE_TEST_EVENTS" && $(< "$work/target") == untouched ]]
rm "$lock"
mkdir "$lock"
run_expect directory 125 /bin/true
[[ ! -s "$BLE_TEST_EVENTS" ]]
rmdir "$lock"
mkfifo "$lock"
run_expect fifo 125 /bin/true
[[ ! -s "$BLE_TEST_EVENTS" ]]
echo "SUPERVISOR_TEST COMPLETE cases=20 hardware=false artifacts=$work"
