#!/usr/bin/env bash

# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

set -euo pipefail

if (( $# != 3 )); then
  echo "Usage: $0 ENVELOPES_ROOT ENVELOPE_TOOL JAGUAR_SNAPSHOT" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENVELOPES_ROOT="$(realpath "$1")"
ENVELOPE_TOOL="$(realpath "$2")"
JAGUAR_SNAPSHOT="$(realpath "$3")"
SDK_DIR="${ROOT_DIR}/build/host/sdk"

mkdir -p "${ROOT_DIR}/build"
WORK_DIR="$(mktemp -d "${ROOT_DIR}/build/partition-size-variants.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

variant_list="$("${ENVELOPE_TOOL}" list "${ENVELOPES_ROOT}/variants")"
if [[ -z "${variant_list}" ]]; then
  echo "No envelope variants found" >&2
  exit 1
fi
mapfile -t variants <<< "${variant_list}"

# Use the same source and build paths for variants of the same chip, as the
# envelopes release workflow does, so ccache can share compilation results.
export CCACHE_BASEDIR="${WORK_DIR}"
export CCACHE_NOHASHDIR=true

failed=()
for variant in "${variants[@]}"; do
  echo "Checking envelope variant: ${variant}"
  source_dir="${WORK_DIR}/source/${variant}"
  if ! "${ENVELOPE_TOOL}" synthesize \
      --toit-root="${ROOT_DIR}" --sdk-path="${SDK_DIR}" \
      --variants-root="${ENVELOPES_ROOT}/variants" \
      --output-root="${WORK_DIR}/source" --build-root="${WORK_DIR}/native" \
      "${variant}"; then
    echo "FAIL: ${variant} synthesis" >&2
    failed+=("${variant}")
    continue
  fi

  chip="${variant%%-*}"
  canonical_source="${WORK_DIR}/source/_build_${chip}"
  canonical_build="${WORK_DIR}/native/_build_${chip}"
  cp -a "${source_dir}" "${canonical_source}"
  if make -C "${canonical_source}" BUILD_PATH="${canonical_build}" &&
      bash "${ROOT_DIR}/tests/esp32/check-partition-sizes.sh" \
        "${JAGUAR_SNAPSHOT}" "${canonical_build}/firmware.envelope"; then
    echo "PASS: ${variant}"
  else
    echo "FAIL: ${variant} build or partition size" >&2
    failed+=("${variant}")
  fi
  # Keep only one native build on disk at a time. Compiled objects remain in
  # ccache for subsequent variants and nightly runs.
  rm -rf "${canonical_source}" "${canonical_build}"
done

if (( ${#failed[@]} )); then
  printf 'Failed envelope variant: %s\n' "${failed[@]}" >&2
  exit 1
fi
