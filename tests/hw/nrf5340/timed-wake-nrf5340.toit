// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import nrf5340
import system.power
import zephyr

main:
  print "TIMED WAKE boot cause=$(power.reset-reason)"
  // P1.00 wakes high; P1.01 wakes low. Both are inactive with these pulls.
  zephyr.configure-wakeup-pin nrf5340.P1-00 --pull-down
  zephyr.configure-wakeup-pin nrf5340.P1-01 --no-wake-high --pull-up
  // Replace, then disable this source to check that stale configuration is
  // not left armed. P1.02 must not wake this probe.
  zephyr.configure-wakeup-pin nrf5340.P1-02 --pull-down
  zephyr.configure-wakeup-pin nrf5340.P1-02 --no-wake-high --pull-up
  zephyr.disable-wakeup-pin nrf5340.P1-02
  sleep --ms=2000
  print "TIMED WAKE entering 60 seconds; P1.00 high or P1.01 low wakes early"
  power.deep-sleep (Duration --s=60)
