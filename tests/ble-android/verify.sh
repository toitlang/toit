#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo "Usage: $0 CAMPAIGN RUN_ID EXCHANGES_PER_CYCLE CYCLES" >&2
  exit 2
fi
campaign=$1
run_id=$2
count=$3
cycles=$4
[[ $run_id =~ ^[A-Za-z0-9_-]{1,64}$ ]]
[[ $count =~ ^[1-9][0-9]*$ && $cycles =~ ^[1-9][0-9]*$ ]]
(( count <= 1000 && cycles <= 100 ))
# These are bounded observation exits, accepted only with terminal assertions.
[[ $(cat "$campaign/board-exit.txt") == 124 ]]
[[ $(cat "$campaign/android-exit.txt") == 124 ]]
awk -v run="$run_id" -v count="$count" -v cycles="$cycles" '
  BEGIN { done=0; passes=0 }
  index($0, "run=" run " ") {
    if ($0 ~ / FAIL /) bad=1
    if ($0 ~ / CYCLE /) {
      expected="CYCLE cycle=" done " exchanges=" count " initial-read=true final-read=true unsubscribed=true disconnected=true"
      if (!index($0, expected)) bad=1
      done++
    }
    if ($0 ~ / PASS /) {
      expected="PASS exchanges=" count*cycles " cycles=" cycles " initial-read=true final-read=true unsubscribed=true disconnected=true"
      if (!index($0, expected) || done != cycles) bad=1
      passes++
    }
  }
  END { if (bad || done != cycles || passes != 1) exit 1 }
' "$campaign/android.log"
awk -v count="$count" -v cycles="$cycles" '
  BEGIN { n=0; done=0; handlers=0; reconnects=0; terminal=0; sleep_seen=0 }
  /EXCEPTION|DEADLINE_EXCEEDED|RECONNECT_COUNT_MISMATCH|RETAINED_VALUE_CHANGED/ { bad=1 }
  /^GATT_SERVER ECHO / {
    expected=sprintf("count=%d data=%02x%02x0000546f6974484349", n+1, n%256, int(n/256))
    if ($0 != "GATT_SERVER ECHO " expected || n >= count) bad=1
    n++
  }
  /^GATT_SERVER HANDLERS / {
    if ($3 != "reads=2" || $4 != "validated=" count || n != count) bad=1
    handlers++
  }
  /^GATT_SERVER COMPLETE / {
    split($4, gc, "=")
    if ($3 != "count=" count || n != count || gc[2] < int(count/10)) bad=1
    n=0
    done++
  }
  /^VHCI_RECONNECT cycle=/ {
    if ($2 != "cycle=" reconnects || done != reconnects+1) bad=1
    reconnects++
  }
  /^VHCI_RECONNECT COMPLETE / {
    if ($3 != "cycles=" cycles || reconnects != cycles) bad=1
    terminal++
  }
  /entering deep sleep without wakeup time/ { sleep_seen++ }
  END {
    if (bad || n || done != cycles || handlers != cycles || sleep_seen != 1) exit 1
    if (cycles > 1 && (reconnects != cycles || terminal != 1)) exit 1
  }
' "$campaign/board.log"
echo "PASS run=$run_id cycles=$cycles exchanges=$((count * cycles))"
