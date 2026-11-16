// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import ec618
import system.power

// Run without other containers managing these wake sources.
main:
  try:
    ec618.configure-wakeup-input ec618.WAKEUP-INPUT-0 --pos-edge --neg-edge --pull-up
    ec618.configure-wakeup-pad 42 --pos-edge --neg-edge --pull-down
    sources := power.wakeup-sources
    found-input := false
    found-pad := false
    sources.do: |source|
      if source is power.InputWakeup and source.input == 0:
        found-input = true
        expect-equals power.WAKE-EDGE source.trigger
        expect-equals null source.wake-high
        expect-equals true source.pull-up
      if source is power.PinWakeup and source.pins.contains 42:
        found-pad = true
        expect-equals power.WAKE-EDGE source.trigger
        expect-equals null source.wake-high
        expect-equals true source.pull-down
    expect found-input
    expect found-pad
    print "EC618 LEGACY WAKE SNAPSHOT PASS"
  finally:
    ec618.disable-wakeup-input ec618.WAKEUP-INPUT-0
    ec618.disable-wakeup-pad 42
