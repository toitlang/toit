#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Per program of a hwinstall log: number of accepted installs, the
# verification time ([install-trace], trace builds) and the whole install
# time (TIME install-*), median and min-max, in seconds; and the peak heap
# use of the verification.
# Usage: install-table.sh LOG-NAME...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
for f in "$@"; do
  echo "== $f"
  tr -d '\r' < "$A/logs/$f.txt" | awk '
    /\[install-trace\] (accepted|rejected):/ { v = $0; sub(/.*; /, "", v); sub(/ us.*/, "", v); pv = $0; sub(/.*peak use /, "", pv); sub(/ B.*/, "", pv); next }
    /^TIME install-/ { name = $2; sub(/^install-/, "", name); t[name] = t[name] " " $3; if (v != "") { ver[name] = ver[name] " " v; peak[name] = pv }; v = ""; n[name]++; order[name] = ++k }
    function stats(s,   a, m, i, j, x) {
      m = split(s, a, " "); if (m == 0) return "-"
      for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (a[j] + 0 < a[i] + 0) { x = a[i]; a[i] = a[j]; a[j] = x }
      return sprintf("%.2f (%.2f-%.2f)", a[int((m + 1) / 2)] / 1e6, a[1] / 1e6, a[m] / 1e6)
    }
    END {
      for (name in n) printf "%-16s n=%d  verify %-22s install %-22s peak %s\n", name, n[name], stats(ver[name]), stats(t[name]), peak[name]
    }' | sort
done
