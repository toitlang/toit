#!/usr/bin/env bash
# Wall time per iteration (as the benchmark prints it), minimum of RUNS
# runs, configurations interleaved. Usage: wall.sh RUNS NAME=BIN:FMT ...
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
RUNS=${1:-5}; shift
declare -A best
echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
for _ in $(seq "$RUNS"); do
  for b in richards deltablue pystone; do
    for c in "$@"; do
      name=${c%%=*}; rest=${c#*=}; bin=${rest%:*}; fmt=${rest##*:}
      v=""; [ "$fmt" = f2 ] && v=1
      t=$(env TOIT_VERIFY=$v "$bin" "$A/snap/$b-$fmt.snap" | sed -nE 's/.*time per iteration: ([0-9.]+) ms.*/\1/p' | tail -1)
      k="$name $b"
      if [ -z "${best[$k]:-}" ] || awk -v a="$t" -v b="${best[$k]}" 'BEGIN { exit !(a < b) }'; then best[$k]=$t; fi
    done
  done
done
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)"
for c in "$@"; do
  name=${c%%=*}
  echo "$name richards=${best[$name richards]} deltablue=${best[$name deltablue]} pystone=${best[$name pystone]}"
done
