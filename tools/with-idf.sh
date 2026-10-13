#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
set -eo pipefail
if [[ $# -lt 2 ]]; then
  echo "usage: $0 IDF-DIRECTORY COMMAND [ARGUMENTS...]" >&2
  exit 1
fi
export IDF_PATH="$(cd "$1" && pwd)"
shift
# Each build activates its own Python environment, even when another IDF was sourced.
for previous_env in "${IDF_PYTHON_ENV_PATH:-}" "${VIRTUAL_ENV:-}"; do
  if [[ -n "$previous_env" ]]; then
    PATH=":$PATH:"
    PATH="${PATH//:$previous_env\/bin:/:}"
    PATH="${PATH#:}"
    PATH="${PATH%:}"
  fi
done
unset VIRTUAL_ENV IDF_PYTHON_ENV_PATH IDF_VERSION ESP_IDF_VERSION ESP_PYTHON
source "$IDF_PATH/export.sh"
exec "$@"
