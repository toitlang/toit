#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo 'The runtime-library check is defined for Linux builds only.' >&2
  exit 2
fi

binary=${1:?usage: check-linux-runtime.sh OTA-UPLOAD [MAX-GLIBC-VERSION]}
maximum_glibc=${2:-}
architecture=$(uname -m)
case "$architecture" in
  x86_64) loader=ld-linux-x86-64.so.2 ;;
  aarch64) loader=ld-linux-aarch64.so.1 ;;
  *)
    echo "No reviewed runtime-library policy for Linux architecture: $architecture" >&2
    exit 2
    ;;
esac

command -v readelf >/dev/null || {
  echo 'Missing check prerequisite: readelf' >&2
  exit 2
}

interpreter=$(readelf -l "$binary" |
  sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
if [[ -z "$interpreter" || ${interpreter##*/} != "$loader" ]]; then
  echo "Unexpected ELF interpreter: ${interpreter:-none}" >&2
  exit 1
fi

unexpected=false
while IFS= read -r library; do
  case "$library" in
    libc.so.6|libm.so.6|"$loader") ;;
    *)
      echo "Unexpected runtime library: $library" >&2
      unexpected=true
      ;;
  esac
done < <(readelf -d "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
if [[ $unexpected == true ]]; then exit 1; fi

if [[ -n "$maximum_glibc" ]]; then
  required_glibc=$(readelf --version-info "$binary" |
    sed -n 's/.*Name: GLIBC_\([0-9.]*\).*/\1/p' |
    sort -V | tail -n 1)
  if [[ -z "$required_glibc" ]]; then
    echo 'Unable to determine the required glibc version.' >&2
    exit 1
  fi
  highest=$(printf '%s\n%s\n' "$maximum_glibc" "$required_glibc" |
    sort -V | tail -n 1)
  if [[ "$highest" != "$maximum_glibc" ]]; then
    echo "glibc $required_glibc exceeds the release baseline $maximum_glibc" >&2
    exit 1
  fi
fi

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
cp "$binary" "$temporary/ota-upload"
(cd "$temporary" && env -i PATH=/usr/bin:/bin ./ota-upload --help >/dev/null 2>&1)

echo "Linux runtime dependency policy: PASS ($architecture${maximum_glibc:+, glibc <= $maximum_glibc})"
