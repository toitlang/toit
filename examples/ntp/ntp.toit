// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import esp32
import log
import ntp

main:
  logger := log.default.with_name "ntp"
  result := ntp.synchronize
  if not result: return
  esp32.adjust_real_time_clock result.adjustment
  logger.info "synchronized" --tags={
    "adjustment": result.adjustment,
    "time": Time.now.local,
  }
