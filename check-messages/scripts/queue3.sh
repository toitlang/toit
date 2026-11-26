#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Third round: the dictionary modes with silent ISR variants.
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
S=$A/scripts
bash $S/fwv.sh esp32 f2 f2dictisr CONFIG_LOG_CHECK_MESSAGES_DICT=y CONFIG_LOG_CHECK_MESSAGES_ISR_SILENT=y
bash $S/fwv.sh esp32 f2 f2dictallisr CONFIG_LOG_CHECK_MESSAGES_DICT=y CONFIG_LOG_DICT_ESP_LOG=y CONFIG_LOG_CHECK_MESSAGES_ISR_SILENT=y
bash $S/fwv.sh esp32 f1 f1dictallisr CONFIG_LOG_CHECK_MESSAGES_DICT=y CONFIG_LOG_DICT_ESP_LOG=y CONFIG_LOG_CHECK_MESSAGES_ISR_SILENT=y
bash $S/fwv.sh esp32c6 f2 f2dictallisr CONFIG_LOG_CHECK_MESSAGES_DICT=y CONFIG_LOG_DICT_ESP_LOG=y CONFIG_LOG_CHECK_MESSAGES_ISR_SILENT=y
bash $S/fwv.sh esp32 f2 f2addrisr CONFIG_LOG_CHECK_MESSAGES_ADDRESS=y CONFIG_LOG_CHECK_MESSAGES_ISR_SILENT=y
bash $S/fwv.sh esp32c6 f2 f2addr CONFIG_LOG_CHECK_MESSAGES_ADDRESS=y
