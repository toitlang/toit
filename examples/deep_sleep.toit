// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import esp32

main:
  run-time ::= Duration --us=esp32.total-run-time
  sleep-time ::= Duration --us=esp32.total-deep-sleep-time
  print "Awake for $(run-time - sleep-time) so far"
  print "Slept for $sleep-time so far"
  esp32.deep-sleep (Duration --s=10)
