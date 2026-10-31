// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import gpio
import gpio.adc show Adc

main arguments:
  if arguments["operation"] == "critical-failure":
    // Let the controller enter its wait while its I2C transfer remains pending.
    sleep --ms=20
    print "LIFECYCLE critical failure: $(arguments["failure"])"
    if arguments["failure"] == "throw": throw "expected critical exception"
    exit 23
  pin := gpio.Pin 5 --output --value=1
  adc := Adc 4
  adc.get
  if arguments["operation"] == "throw": throw "expected noncritical exception"
  if arguments["operation"] == "hold":
    while true: sleep --ms=100
  exit arguments["code"]
