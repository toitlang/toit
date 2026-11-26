#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: summary of a host allocation log of one verification
# (VALLOC lines of the measurement patch patches/vmverify-alloclog.patch):
# count, size histogram, live peak, the largest blocks with where they were
# allocated and how long they lived (in allocation events).
# Usage: valloc-summary.sh LOG [TOP]
LOG=$1
TOP=${2:-15}
grep '^VALLOC' "$LOG" | awk -v top="$TOP" '
{
  seq=$2; kind=$3; p=$4; old=$5; size=$6; osize=$7
  w=""; for (i=8;i<=NF;i++) w=w" "$i
  if (kind=="A") { n++; live+=size; sz[p]=size; at[p]=seq; hist(size) }
  else if (kind=="F") { live-=sz[p]; life[at[p]]=seq-at[p]; delete sz[p] }
  else if (kind=="R") { nr++; live+=size-sz[old]; life[at[old]]=seq-at[old]; delete sz[old]; sz[p]=size; at[p]=seq; hist(size) }
  if (live>peak) { peak=live; peakseq=seq }
  if (kind!="F") { big[seq]=size; bigw[seq]=w }
}
function hist(s,  b) { b = s<64?"<64":s<256?"64-255":s<1024?"256-1023":s<2048?"1-2K":s<4096?"2-4K":s<8192?"4-8K":">=8K"; h[b]++ }
END {
  printf "allocations %d, reallocations %d, live peak %d B at event %d, live at end %d B\n", n, nr, peak, peakseq, live
  printf "sizes:"; split("<64 64-255 256-1023 1-2K 2-4K 4-8K >=8K", o, " "); for (i=1;i<=7;i++) printf " %s:%d", o[i], h[o[i]]+0; printf "\n"
  m=0; for (s in big) { list[m++]=big[s]" "s }
  for (k=0;k<top;k++) {
    best=-1; bi=-1
    for (j=0;j<m;j++) { split(list[j], a, " "); if (a[1]+0>best && !(j in used)) { best=a[1]+0; bi=j } }
    if (bi<0) break
    used[bi]=1; split(list[bi], a, " "); s=a[2]
    printf "  %6d B at event %6d, lived %s events:%s\n", a[1], s, (s in life)?life[s]:"(to the end)", bigw[s]
  }
}'
