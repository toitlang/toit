#!/usr/bin/env bash
# Collects the device_size.sh outputs of libsizes.sh (device-cert/libsizes-*.txt)
# into one markdown table: per variant and opt-level, text by component (KB),
# Rust text total and linked rodata. Usage: sizetable.sh VARIANT...
cd /home/flo/work/opentoit-sandbox-artifacts/device-cert
cat libsizes-*.txt | awk -v variants="$*" '
BEGIN {
  n = split(variants, vs, " ")
  split("core: verified loop and cold paths|core: checked loop|core: primitives|verifier: checker|verifier: heap check|verifier: inference|glue (vmverify)|rust: formatting|rust: panics|rust: other core/alloc|compiler builtins|spec: other", comps, "|")
}
/^opt[3sz]-.*: linked text/ {
  split($1, a, "-"); opt = substr(a[1], 4); v = substr($1, length(a[1]) + 2); sub(/:$/, "", v)
  cur = v "/" opt
  ro[cur] = $7 - 12
  next
}
/^\| / && cur != "" {
  split($0, f, "|"); c = f[2]; gsub(/^ +| +$/, "", c); t = f[3] + 0
  text[cur, c] = t
  if (c != "libc" && c != "C stubs" && c !~ /^Rust library/ && c != "Component") total[cur] += t
}
END {
  printf "| Component (KB) |"
  for (i = 1; i <= n; i++) printf " %s 3 | s | z |", vs[i]
  printf "\n|---|"
  for (i = 1; i <= n; i++) printf "---|---|---|"
  printf "\n"
  for (j = 1; j <= 12; j++) {
    printf "| %s |", comps[j]
    for (i = 1; i <= n; i++) for (k = 1; k <= 3; k++) {
      o = substr("3sz", k, 1); printf " %.1f |", text[vs[i] "/" o, comps[j]] / 1000
    }
    printf "\n"
  }
  printf "| Rust text total |"
  for (i = 1; i <= n; i++) for (k = 1; k <= 3; k++) { o = substr("3sz", k, 1); printf " %.1f |", total[vs[i] "/" o] / 1000 }
  printf "\n| rodata (linked) |"
  for (i = 1; i <= n; i++) for (k = 1; k <= 3; k++) { o = substr("3sz", k, 1); printf " %.1f |", ro[vs[i] "/" o] / 1000 }
  printf "\n| text + rodata |"
  for (i = 1; i <= n; i++) for (k = 1; k <= 3; k++) { o = substr("3sz", k, 1); printf " %.1f |", (total[vs[i] "/" o] + ro[vs[i] "/" o]) / 1000 }
  printf "\n"
}'
