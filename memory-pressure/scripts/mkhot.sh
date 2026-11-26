#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: the ordered list for TOIT_HOT_FLASH_FUNCTIONS from
# func-samples.sh tables (TSV: samples, share, size, region, mangled, name).
# Each table counts with the same weight (samples / its flash samples;
# NORM=all: samples / all its samples, i.e. the share of the time).
# Flash functions only, without the measurement code (hw_perf_*); ranked by
# weight per byte; taken in that order while the sizes fit BUDGET bytes
# (functions of at least MINSHARE % of one table's flash samples are
# always considered first). Rust v0 names become globs from the crate
# name on (the crate hash differs between builds).
# Prints "glob<TAB>size<TAB>score<TAB>name" lines when VERBOSE=1, else the
# comma-separated list.
# Usage: mkhot.sh BUDGET TSV...
set -uo pipefail
BUDGET=$1
shift
awk -F'\t' -v budget="$BUDGET" -v verbose="${VERBOSE:-0}" -v norm="${NORM:-flash}" '
  FNR == 1 { src++ }
  norm == "all" { tot[src] += $1 }
  $4 == "flash" && $5 !~ /hw_perf/ { s[src, $5] = $1; if (norm != "all") tot[src] += $1; size[$5] = $3; name[$5] = $6; seen[$5] = 1 }
  END {
    for (k in seen) { sc = 0; for (i = 1; i <= src; i++) if (tot[i] > 0) sc += s[i, k] / tot[i]; score[k] = sc / src }
    n = 0; for (k in seen) { n++; key[n] = k; d[k] = score[k] / (size[k] > 16 ? size[k] : 16) }
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (d[key[j]] > d[key[i]]) { t = key[i]; key[i] = key[j]; key[j] = t }
    used = 0; out = ""
    for (i = 1; i <= n; i++) {
      k = key[i]
      if (used + size[k] > budget) continue
      used += size[k]
      g = k; sub(/^_R.*Cs[0-9A-Za-z]+_/, "*", g)
      if (verbose) printf "%s\t%d\t%.5f\t%s\n", g, size[k], score[k], name[k]
      out = out (out == "" ? "" : ",") g
    }
    if (!verbose) print out
    else printf "total %d bytes\n", used
  }' "$@"
