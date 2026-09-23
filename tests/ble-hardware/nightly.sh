#!/bin/bash
# Runs the hardware campaigns and checks of docs/ble/hardware.md in sequence
# and prints one line per step. Intended for a cron job on the rig host;
# every step leaves its logs under build/.
#
# Usage: tests/ble-hardware/nightly.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
summary=()
run() { local name=$1; shift; if "$@" > "build/nightly-$name.log" 2>&1; then summary+=("$name: pass"); else summary+=("$name: FAIL (build/nightly-$name.log)"); fi; }
getcap build/host/sdk/lib/toit/bin/toit.run | grep -q cap_net_admin || echo "warning: toit.run lacks cap_net_admin; Linux steps will fail"
run "resume-pair" build/ble-resume-features-003/run-phase.sh pair
run "resume-resume" build/ble-resume-features-003/run-phase.sh resume
run "revocation" build/ble-mic-003/run.sh "nightly-$(date +%Y%m%d)"
run "bench-toit" build/ble-bench-001/run.sh toit 5
run "bench-direct" build/ble-bench-001/run.sh direct 5
run "compat" tests/ble-hardware/compat.sh
run "multi-central" tests/ble-hardware/multi-central-check.sh
printf '%s\n' "${summary[@]}"
# Pass criteria per step (grep the logs): resume phases print CENTRAL_FRESH COMPLETE
# with resumed=true in the resume phase; revocation prints REVOKE_TWO COMPLETE and
# both peers REVOKE_AUTH COMPLETE; bench prints central-exit=0; compat prints
# COMPAT COMPLETE and the board Heart rate app received data.
for f in resume-pair resume-resume revocation bench-toit bench-direct compat multi-central; do
  printf '%-14s ' "$f"; grep -aoh "CENTRAL_FRESH COMPLETE[^ ]*\|REVOKE_TWO COMPLETE\|REVOKE_AUTH COMPLETE peer=[01]\|central-exit=[0-9]\|COMPAT COMPLETE\|Heart rate app received data" "build/nightly-$f.log" 2>/dev/null | sort | uniq -c | tr '\n' ';'; echo
done
