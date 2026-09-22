#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: verify-cccd.sh CAMPAIGN RUN_PREFIX' >&2; exit 2; }
campaign=$1
prefix=$2
[[ $prefix =~ ^[A-Za-z0-9_-]{1,59}$ ]]
for phase in pair resume; do
  directory="$campaign/$phase"
  run="$prefix-$phase"
  # Captures may be interrupted after terminal assertions, or end at their bound.
  [[ $(cat "$directory/board-exit.txt") =~ ^(1|124|130)$ ]]
  [[ $(cat "$directory/android-exit.txt") =~ ^(124|130)$ ]]
  rg -q '^ANDROID_CCCD COMPLETE phase='"$phase"'$' "$directory/runner.log"
  rg -q 'showing=false' "$directory/power-start.txt"
  rg -q 'showing=false' "$directory/power-end.txt"
  awk -v run="$run" -v phase="$phase" '
    BEGIN { cycles=0; passes=0; numbers=0; starts=0 }
    index($0, "run=" run " ") {
      if ($0 ~ / FAIL /) bad=1
      if ($0 ~ / START /) {
        if (!index($0, "START phase=" phase " ") || !index($0, " cycles=2 ")) bad=1
        starts++
      }
      if ($0 ~ / NUMERIC /) numbers++
      if ($0 ~ / CYCLE /) {
        resumed=(phase=="resume" || cycles>0) ? "true" : "false"
        writes=(resumed=="true") ? 0 : 2
        expected="CYCLE cycle=" cycles " resumed=" resumed " notifications=20 indications=20 service-changed=1 app-cccd-writes=" writes " bonded=true disconnected=true"
        # Android may leave initial Service Changed setup to the test app.
        alternative="CYCLE cycle=0 resumed=false notifications=20 indications=20 service-changed=1 app-cccd-writes=3 bonded=true disconnected=true"
        if (!index($0, expected) && !(phase=="pair" && cycles==0 && index($0, alternative))) bad=1
        cycles++
      }
      if ($0 ~ / PASS /) {
        if (cycles!=2 || !index($0, "PASS phase=" phase " cycles=2 notifications=40 indications=40 service-changed=2 bonded=true")) bad=1
        passes++
      }
    }
    END { if (bad || starts!=1 || cycles!=2 || passes!=1 || numbers!=(phase=="pair" ? 1 : 0)) exit 1 }
  ' "$directory/android.log"
  awk -v phase="$phase" '
    BEGIN { apps=0; providers=0; sent=0; secure=0; groups=0; complete=0; sleeping=0; numbers=0 }
    /EXCEPTION|ASSERTION_FAILED/ { bad=1 }
    /^CCCD_PERSIST NUMERIC / { numbers++ }
    /^CCCD_PERSIST SECURE / {
      if ($3!="cycle=" secure || $4!="resumed=" ((phase=="resume" || secure>0) ? "true" : "false") || $5!="authenticated=true") bad=1
      secure++
    }
    /^CCCD_PERSIST SENT / {
      if ($3!="cycle=" sent || $4!="indications-confirmed=21") bad=1
      sent++
    }
    /^CCCD_SERVICE_APP COMPLETE / {
      expected=(phase=="resume" || apps>0) ? "true" : "false"
      split($9, gc, "=")
      if ($3!="cycle=" apps || $4!="resumed=" expected || $6!="notifications=20" ||
          $7!="indications=20" || $8!="service-changed=1" || gc[2]<20 ||
          $10!="application-cccd-writes=" (expected=="true" ? 0 : 2) || $11!="retained=true") bad=1
      apps++
    }
    /^CCCD_ANDROID_PROVIDER COMPLETE / {
      split($5, gc, "=")
      if ($3!="cycle=" providers || $4!="resumed=" ((phase=="resume" || providers>0) ? "true" : "false") ||
          gc[2]<20 || $6!="authenticated=true" || $7!="identity-retained=true" || $8!="configuration-retained=true") bad=1
      providers++
    }
    /^CCCD_SERVICE_SUPERVISOR CYCLE / {
      if ($3!="cycle=" groups || $6!="exits=0") bad=1
      groups++
    }
    /^CCCD_SERVICE_SUPERVISOR COMPLETE groups=4 providers=2 applications=2$/ { complete++ }
    /entering deep sleep without wakeup time/ { sleeping++ }
    END { if (bad || apps!=2 || providers!=2 || sent!=2 || secure!=2 || groups!=2 || complete!=1 || sleeping!=1 || numbers!=(phase=="pair" ? 1 : 0)) exit 1 }
  ' "$directory/board.log"
done
[[ $(cat "$campaign/pair/approval.exit") == 0 ]]
rg -q '^NUMERIC matched=true system-dialog-matched=true approved=true$' "$campaign/pair/approval.log"
board_number=$(sed -n 's/^CCCD_PERSIST NUMERIC value=\([0-9]*\) fixture-approval=true.*/\1/p' "$campaign/pair/board.log")
phone_number=$(sed -n 's/.*run='"$prefix"'-pair NUMERIC value=\([0-9]*\) system-confirmation-required=true.*/\1/p' "$campaign/pair/android.log")
[[ $board_number =~ ^[0-9]{1,6}$ && $board_number == "$phone_number" ]]
echo "PASS run=$prefix authenticated-connections=4 notifications=80 indications=80 service-changed=4 retained=true"
