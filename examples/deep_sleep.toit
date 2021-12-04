// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import esp32

main:
  print "Ran for $(Duration --us=esp32.total_run_time) so far"
  print "Slept for $(Duration --us=esp32.total_deep_sleep_time) so far"
  esp32.deep_sleep (Duration --s=10)
