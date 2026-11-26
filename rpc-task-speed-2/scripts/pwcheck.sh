#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Lists files under the given directories that contain the rig's WiFi
# password (prints only file names and counts, never the password).
set +x
# shellcheck disable=SC1091
. /home/flo/work/opentoit-fix-ci/GITIGNORE/esp32-test.env
grep -r -c -F -- "$ESP32_WIFI_PASSWORD" "$@" 2> /dev/null | grep -v ":0$"
echo "pwcheck done"
