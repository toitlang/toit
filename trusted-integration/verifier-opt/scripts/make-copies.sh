#!/usr/bin/env bash
# Copies verified/ of the worktree to build/vopt/<level>/verified for each
# verifier+glue opt-level, with the two package entries of
# vmverify/staticlib/Cargo.toml set to that level (the core stays at the
# device profile's level). Measurement only.
# Usage: make-copies.sh <worktree> <level>...
set -euo pipefail
WT=$1
shift
for l in "$@"; do
  d="$WT/build/vopt/$l"
  mkdir -p "$d"
  rsync -a --exclude target "$WT/verified/" "$d/verified/"
  case $l in
    z|s) v="\"$l\"" ;;
    *) v=$l ;;
  esac
  perl -0pi -e "s/(\[profile\.device\.package\.toit_spec\]\nopt-level = )\"z\"/\${1}$v/; s/(\[profile\.device\.package\.toit_vmverify\]\nopt-level = )\"z\"/\${1}$v/" \
    "$d/verified/vmverify/staticlib/Cargo.toml"
  echo "== $l"
  grep -A1 "profile.device" "$d/verified/vmverify/staticlib/Cargo.toml" | grep -v "^--"
done
