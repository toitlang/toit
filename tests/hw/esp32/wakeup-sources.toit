// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import esp32
import system
import system.power

// Run without other containers managing GPIO wake sources.
main:
  original := system.architecture == system.ARCHITECTURE-ESP32
  pins := original ? [32, 33] : [4, 5]
  try:
    esp32.enable-external-wakeup ((1 << pins[0]) | (1 << pins[1])) false
    sources := power.wakeup-sources.filter: it is power.PinWakeup
    expect-equals (original ? 1 : 2) sources.size
    sources.do: |source/power.PinWakeup|
      expect-equals power.WAKE-LEVEL source.trigger
      expect-equals false source.wake-high
      expect-equals original source.all-low
    if original: expect-list-equals pins sources[0].pins

    // Replacing the old mask must also replace the visible configuration.
    esp32.enable-external-wakeup (1 << pins[0]) true
    sources = power.wakeup-sources.filter: it is power.PinWakeup
    expect-equals 1 sources.size
    expect-list-equals [pins[0]] sources[0].pins
    expect-equals true sources[0].wake-high
    expect-equals false sources[0].all-low
    expect-throw "ERROR": esp32.enable-external-wakeup (1 << 63) true
    sources = power.wakeup-sources.filter: it is power.PinWakeup
    expect-equals 1 sources.size
    expect-list-equals [pins[0]] sources[0].pins
    expect-equals true sources[0].wake-high
    print "ESP32 LEGACY WAKE SNAPSHOT PASS"
  finally:
    pins.do: power.disable-wakeup-pin it
