// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ntp
import esp32

main:
  print "Before: Time is $(Time.now)"
  sync := ntp.synchronize
  if sync: esp32.adjust_real_time_clock sync.adjustment
  print "After: Time is $(Time.now)"
