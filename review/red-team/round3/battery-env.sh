# Shared setup of the round-3 batteries (battery-heap.sh, battery-asm.sh),
# sourced. Paths are relative to the repository (the batteries run from its
# root); override with the environment:
#   HOSTRUN  the normal toit.run (default build/host/sdk/lib/toit/bin/toit.run)
#   ASANRUN  the second build: ASan/UBSan, or a Debug build to catch
#            assertions (default build/asan/sdk/lib/toit/bin/toit.run)
#   WORK     output directory (default build/rt3): the compiled base
#            snapshots, the crafted snapshots, the results
#   RES      the results file (default $WORK/<battery>-results.txt)
# The base snapshots are compiled from repro/*.toit in bytecode format 2 with
# the normal build's compiler; the object and dispatch indices the batteries
# use (see their headers) are those of that compilation.
# `battery_finish` ends a battery: it fails (exit 1) if a case crashed or
# hit a sanitizer report or an assertion, or if a case's verdict on the
# normal build differs from the recorded one (repro/<battery>-results.txt).

HERE_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${WT:-$(cd "$HERE_ENV/../../.." && pwd)}"
cd "$WT" || exit 2
HOSTRUN="${HOSTRUN:-build/host/sdk/lib/toit/bin/toit.run}"
ASANRUN="${ASANRUN:-build/asan/sdk/lib/toit/bin/toit.run}"
WORK="${WORK:-build/rt3}"
mkdir -p "$WORK"
if [ ! -x "$HOSTRUN" ]; then echo "no $HOSTRUN" >&2; exit 2; fi
if [ ! -x "$ASANRUN" ]; then echo "no $ASANRUN (set ASANRUN)" >&2; exit 2; fi

# battery_compile SOURCE SNAPSHOT: compiles SOURCE in format 2.
battery_compile () {
  TOIT_BYTECODE_FORMAT=2 "$(dirname "$HOSTRUN")/toit.compile" -w "$2" "$1"
}

# battery_finish heap|asm: the verdict of the run in $RES against $EXPECTED.
battery_finish () {
  local kind=$1
  echo "# done $(date)" | tee -a "$RES"
  local bad
  # Tool errors (a case the tool cannot build) are part of the recorded
  # verdicts: a new one shows as a difference below.
  bad=$(grep -E '<<<' "$RES")
  local extract
  if [ "$kind" = heap ]; then
    extract='/^\[/ { n = $1; v = $0; sub(/.*host:\{/, "", v); sub(/ x[^}]*\}.*/, "", v); print n "\t" v }'
  else
    extract='/^\[/ { n = $1; v = $0; sub(/^\[[^]]*\] x\{[^}]*\} /, "", v); sub(/ *<<<.*/, "", v); sub(/ +$/, "", v); print n "\t" v }'
  fi
  local diffs
  diffs=$(diff <(awk "$extract" "$EXPECTED" | sort) <(awk "$extract" "$RES" | sort))
  local status=0
  if [ -n "$bad" ]; then
    echo "battery $kind: crashes, sanitizer reports or assertions:"; echo "$bad"; status=1
  fi
  if [ -n "$diffs" ]; then
    echo "battery $kind: verdicts on the normal build differ from $EXPECTED (< recorded, > now):"; echo "$diffs"; status=1
  fi
  [ $status = 0 ] && echo "battery $kind: $(grep -c '^\[' "$RES") cases, verdicts as recorded, no crash"
  return $status
}
