// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import esp32

main:
  run_time ::= Duration --us=esp32.total_run_time
  sleep_time ::= Duration --us=esp32.total_deep_sleep_time
  print "Awake for $(run_time - sleep_time) so far"
  print "Slept for $sleep_time so far"
  esp32.deep_sleep (Duration --s=10)
