#!/usr/bin/env bash
# Runs a command with the ESP-IDF environment (toolchains on the PATH).
# Usage: idf.sh COMMAND [ARGS...]
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
exec "$@"
