// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import nrf5340
import system.power

main:
  run

// Use the same workload for both modes. P1.00 must be otherwise unconnected;
// a weak external pull-down can be used to observe resource release.
run --timed/bool=true:
  expect power.supports-timed-deep-sleep
  print "POWER CURRENT boot cause=$(power.reset-reason) timed=$timed"
  indicator := gpio.Pin nrf5340.P1-00 --input --output --value=1
  expect-equals 1 indicator.get
  sleep --ms=2000
  print "POWER CURRENT entering $(timed ? "timed 60 s" : "untimed") deep sleep"
  // Leave the GPIO open: VM teardown must disconnect it before sleep.
  try:
    if timed:
      power.deep-sleep (Duration --s=60)
    else:
      power.deep-sleep
    throw "deep-sleep returned"
  finally:
    // Keeps the resource reachable until the power call; a successful sleep
    // does not run this block, so native teardown must release the pin.
    indicator.close
