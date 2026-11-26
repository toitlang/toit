#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Classic ESP32 f2 in the message modes (overlay).
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
S=$A/scripts
bash $S/fwv.sh esp32 f2 f2dictall CONFIG_LOG_CHECK_MESSAGES_DICT=y CONFIG_LOG_DICT_ESP_LOG=y
bash $S/fwv.sh esp32 f2 f2dict CONFIG_LOG_CHECK_MESSAGES_DICT=y
bash $S/fwv.sh esp32 f2 f2addr CONFIG_LOG_CHECK_MESSAGES_ADDRESS=y
bash $S/fwv.sh esp32 f2 f2 CONFIG_LOG_CHECK_MESSAGES_TEXT=y
bash $S/fwv.sh esp32 f2 f2cs CONFIG_COMPILER_OPTIMIZATION_CHECKS_SILENT=y
