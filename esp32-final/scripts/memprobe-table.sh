#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-final: one row per memprobe report (progs/memprobe): kind, number
# of workers, system free memory, and the heap report's bytes per malloc
# tag (toit processes split into the system process, the controller and
# the workers' pages), plus the workers' live/reserved Toit heap and
# bytes allocated per iteration (MPW lines).
# Usage: memprobe-table.sh LOG
set -uo pipefail
tr -d '\r' < "$1" | awk '
  function flush() {
    if (kind == "") return
    printf "| %s | %d | %d | %d | %d | %d | %s | %d | %d | %d | %d | %d | %s | %s |\n",
      kind, n, free, tags["toit processes"], sys, ctl, wpages, tags["thread/other"], tags["untagged"],
      tags["external byte array"], tags["heap overhead"], tags["event source"], live, per
    kind = ""
  }
  /^MP [a-z0-9-]+ n=/ {
    flush()
    kind = $2; n = substr($3, 3); free = $4; sub(/free=/, "", free)
    split("", tags); sys = 0; ctl = 0; wpages = ""; live = ""; per = ""; inrep = 0
    next
  }
  /^MPW / {
    it = $5; sub(/iters=/, "", it); al = $8; sub(/alloc=/, "", al); rs = $9; sub(/reserved=/, "", rs); tot = $10; sub(/total=/, "", tot)
    live = live (live == "" ? "" : " ") al "/" rs
    per = per (per == "" ? "" : " ") (it > 0 ? sprintf("%d", tot / it) : "-")
    next
  }
  /^Heap report @/ { inrep = 1; next }
  inrep && /│/ {
    line = $0
    gsub(/[│┌┐└┘├┤┬┴┼─]/, " ", line)
    m = split(line, f, " ")
    if (m >= 3 && f[1] ~ /^[0-9]+$/ && f[2] ~ /^[0-9]+$/) {
      if (f[3] == "system" || f[3] == "current" || f[3] == "other") {
        if (f[3] == "system") sys = f[1]
        else if (f[3] == "current") ctl = f[1]
        else wpages = wpages (wpages == "" ? "" : "+") f[1]
      } else {
        name = f[3]; for (i = 4; i <= m; i++) name = name " " f[i]
        tags[name] = f[1]
      }
    }
    next
  }
  /Total:/ { inrep = 0 }
  END { flush() }
' | sed '1i | kind | n | free | toit processes | system | controller | worker pages | thread/other | untagged | external byte array | heap overhead | event source | worker live/reserved | worker B allocated per iteration |\n|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---|---|'
