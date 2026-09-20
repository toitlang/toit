#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
base="${1:-$root/build/rp2350-envelope-base/toit-rp2350.bin}"
system_snapshot="${2:-$root/.cache/rp2350/system.snapshot}"
partition_table="${3:-}"
toit="${TOIT:-$root/build/host/sdk/bin/toit}"
package_cache="${TOIT_PACKAGE_CACHE_PATHS:-$root/tools/.packages-bootstrap}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

for input in "$base" "$system_snapshot" "$toit"; do
  if [[ ! -f "$input" ]]; then
    echo "FAIL: required input not found: $input" >&2
    exit 2
  fi
done
if [[ ! -x "$toit" ]]; then
  echo "FAIL: Toit executable is not executable: $toit" >&2
  exit 2
fi

picotool="${PICOTOOL:-}"
if [[ -z "$picotool" ]]; then
  for candidate in \
      "$root/build/rp2350-flasher/linux-x86_64/picotool" \
      "$root/.cache/rp2350/install/bin/picotool"; do
    if [[ -x "$candidate" ]]; then
      picotool="$candidate"
      break
    fi
  done
  if [[ -z "$picotool" ]] && command -v picotool >/dev/null 2>&1; then
    picotool="$(command -v picotool)"
  fi
fi
if [[ -z "$picotool" || ! -x "$picotool" ]]; then
  echo "FAIL: picotool is required; set PICOTOOL to its path" >&2
  exit 2
fi
if [[ -z "$partition_table" ]]; then
  partition_table="$temporary/partitions-experimental.uf2"
  "$picotool" partition create \
    "$root/toolchains/rp2350/partitions-experimental.json" \
    "$partition_table"
elif [[ ! -f "$partition_table" ]]; then
  echo "FAIL: partition-table UF2 not found: $partition_table" >&2
  exit 2
fi

export TOIT_PACKAGE_CACHE_PATHS="$package_cache"
firmware=(
  "$toit" run --project-root "$root/tools" "$root/tools/firmware.toit" --
)
helper=(
  "$toit" run --project-root "$root/tools" \
  "$root/tools/rp2350-envelope-test-helper.toit" --
)

"$toit" compile --snapshot \
  -o "$temporary/child.snapshot" \
  "$root/tools/rp2350/tests/envelope_child.toit"
"${helper[@]}" make-assets "$temporary/assets.bin" 0

"${firmware[@]}" --envelope="$temporary/base.envelope" create-rp2350 \
  --firmware.bin="$base" \
  --partition-table.uf2="$partition_table" \
  --system.snapshot="$system_snapshot"
"${firmware[@]}" --envelope="$temporary/base.envelope" container install \
  --output="$temporary/installed.envelope" \
  --assets="$temporary/assets.bin" \
  --critical \
  child "$temporary/child.snapshot"

"${firmware[@]}" --envelope="$temporary/installed.envelope" show \
  --output="$temporary/show.json"
python3 "$root/tools/rp2350/tests/envelope_fixture.py" \
  verify-show "$temporary/show.json" "$temporary/assets.bin"
"${firmware[@]}" --envelope="$temporary/installed.envelope" container extract \
  --part=assets --output="$temporary/extracted-assets.bin" child
cmp "$temporary/assets.bin" "$temporary/extracted-assets.bin"

cat >"$temporary/config.json" <<'EOF'
{"enabled":true,"name":"rp2350-envelope-test"}
EOF
"${firmware[@]}" --envelope="$temporary/installed.envelope" extract \
  --format=binary --config="$temporary/config.json" \
  --output="$temporary/firmware-1.bin"
"${firmware[@]}" --envelope="$temporary/installed.envelope" extract \
  --format=binary --config="$temporary/config.json" \
  --output="$temporary/firmware-2.bin"
cmp "$temporary/firmware-1.bin" "$temporary/firmware-2.bin"
"${firmware[@]}" --envelope="$temporary/installed.envelope" extract \
  --format=ubjson --config="$temporary/config.json" \
  --output="$temporary/firmware.ubjson"
"${helper[@]}" verify-output \
  "$temporary/firmware.ubjson" \
  "$temporary/firmware-1.bin" \
  "$temporary/assets.bin"

"${firmware[@]}" --envelope="$temporary/installed.envelope" extract \
  --format=image --config="$temporary/config.json" \
  --output="$temporary/bootstrap.uf2"
python3 "$root/tools/rp2350/tests/envelope_fixture.py" verify-uf2 \
  "$temporary/bootstrap.uf2" "$temporary/firmware-1.bin" "$partition_table"

# Mirror the ROM's explicit-buy mutation, then build the same recovery image
# through independent picotool conversion and combination. The pure-Toit
# writer must match it byte for byte.
python3 "$root/tools/rp2350/tests/envelope_fixture.py" mutate \
  terminal-tbyb "$temporary/firmware-1.bin" "$temporary/confirmed.bin"
"$picotool" info -a "$temporary/confirmed.bin" \
  >"$temporary/confirmed-info.txt"
grep -Fq 'hash:                verified' "$temporary/confirmed-info.txt"
if [[ "$(grep -Fc 'tbyb:                not bought' \
    "$temporary/confirmed-info.txt")" != 1 ]]; then
  echo "FAIL: picotool did not report exactly the retained root TBYB flag" >&2
  exit 1
fi
"$picotool" uf2 convert \
  "$temporary/confirmed.bin" "$temporary/program.uf2" \
  --family rp2350-arm-s --platform rp2350 --abs-block >/dev/null
"$picotool" uf2 combine \
  "$partition_table" "$temporary/program.uf2" "$temporary/reference.uf2" \
  --family absolute --partition 0
cmp "$temporary/bootstrap.uf2" "$temporary/reference.uf2"
"$picotool" info -a "$temporary/bootstrap.uf2" \
  >"$temporary/bootstrap-info.txt"
grep -Fq 'partition 0 (A):       00002000->00402000' \
  "$temporary/bootstrap-info.txt"
grep -Fq 'partition 2 (A):       00802000->00ffd000' \
  "$temporary/bootstrap-info.txt"
grep -Fq 'hash:                  verified' "$temporary/bootstrap-info.txt"

cat >"$temporary/fake-ota-upload" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "--port" ]]
[[ "$2" == "/dev/null" ]]
cp "$3" "$RP2350_ENVELOPE_TEST_CAPTURE"
EOF
chmod +x "$temporary/fake-ota-upload"
RP2350_ENVELOPE_TEST_CAPTURE="$temporary/flashed.bin" \
RP2350_OTA_UPLOAD_PATH="$temporary/fake-ota-upload" \
  "${firmware[@]}" --envelope="$temporary/installed.envelope" flash \
    --port=/dev/null --config="$temporary/config.json"
cmp "$temporary/firmware-1.bin" "$temporary/flashed.bin"

for mutation in hash root-tbyb terminal-tbyb; do
  python3 "$root/tools/rp2350/tests/envelope_fixture.py" mutate \
    "$mutation" "$base" "$temporary/$mutation.bin"
  if "${firmware[@]}" --envelope="$temporary/$mutation.envelope" create-rp2350 \
      --firmware.bin="$temporary/$mutation.bin" \
      --partition-table.uf2="$partition_table" \
      --system.snapshot="$system_snapshot" \
      >"$temporary/$mutation.log" 2>&1; then
    echo "FAIL: malformed RP2350 base was accepted ($mutation)" >&2
    exit 1
  fi
done

for mutation in partition-hash partition-layout; do
  python3 "$root/tools/rp2350/tests/envelope_fixture.py" mutate \
    "$mutation" "$partition_table" "$temporary/$mutation.uf2"
  if "${firmware[@]}" --envelope="$temporary/$mutation.envelope" create-rp2350 \
      --firmware.bin="$base" \
      --partition-table.uf2="$temporary/$mutation.uf2" \
      --system.snapshot="$system_snapshot" \
      >"$temporary/$mutation.log" 2>&1; then
    echo "FAIL: malformed RP2350 partition table was accepted ($mutation)" >&2
    exit 1
  fi
done

"${helper[@]}" make-assets "$temporary/oversized-assets.bin" 4194304
"${firmware[@]}" --envelope="$temporary/base.envelope" container install \
  --output="$temporary/oversized.envelope" \
  --assets="$temporary/oversized-assets.bin" \
  child "$temporary/child.snapshot"
if "${firmware[@]}" --envelope="$temporary/oversized.envelope" extract \
    --format=binary --output="$temporary/oversized.bin" \
    >"$temporary/oversized.log" 2>&1; then
  echo "FAIL: RP2350 image larger than its slot was accepted" >&2
  exit 1
fi
if ! grep -Eq 'exceed(s|ed)? (the )?firmware slot|image exceeds' \
    "$temporary/oversized.log"; then
  cat "$temporary/oversized.log" >&2
  echo "FAIL: oversized image failed for an unexpected reason" >&2
  exit 1
fi

PICOTOOL="$picotool" REQUIRE_PICOTOOL=1 \
  "$root/tools/rp2350/tests/run_ota_image_parser_tests.sh" \
  "$temporary/firmware-1.bin"

echo "rp2350_envelope_test: PASS create/install/extract/flash and negative cases"
