// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio.adc show Adc
import monitor
import system.containers

raw-group := null
raw-resource := null

main args:
  if args is Map:
    child args
    return
  with-timeout --ms=60_000:
    test-notifications
    test-cancellation
    test-containers
  print "ADC EVENTS PASS"

check-raw value/int:
  expect 0 <= value <= 4095

check-volts value/float:
  expect 0.0 <= value <= 3.9

// Waiting directly on the resource proves that real completion events arrive;
// the public library's timeout fallback cannot make this test pass.
test-notifications:
  group := native-group
  [0, 1].do: |channel/int|
    resource := native-open group channel
    events := monitor.ResourceState_ group resource
    try:
      100.repeat:
        events.clear
        expect-equals null (native-raw resource)
        expect-equals 1 (with-timeout --ms=20: events.wait)
        check-raw (native-raw resource)
      50.repeat:
        events.clear
        expect-equals null (native-get resource 64)
        native-cancel resource
        // Switch request kind immediately: an old completion must not leave
        // the channel owned by the abandoned voltage request.
        while true:
          events.clear
          value := native-raw resource
          if value:
            check-raw value
            break
          with-timeout --ms=20: events.wait
    finally:
      events.dispose
      native-close resource
    100.repeat:
      resource = native-open group channel
      expect-equals null (native-raw resource)
      native-close resource
      resource = native-open group channel
      native-close resource
  print "ADC direct notifications, cancel/switch, close-after-start PASS"

test-cancellation:
  adc0 := Adc.channel 0
  adc1 := Adc.channel 1
  try:
    other-done := monitor.Latch
    other-error := null
    task::
      try:
        other-error = catch:
          100.repeat:
            check-volts (adc1.get --samples=17)
            check-raw (adc1.get --raw)
      finally:
        other-done.set true
    10.repeat:
      error := catch: with-timeout --ms=2: adc0.get --samples=1_000_000
      expect-equals DEADLINE-EXCEEDED-ERROR error
      check-raw (adc0.get --raw)
      check-volts (adc0.get --samples=3)
    other-done.get
    expect-equals null other-error
    print "ADC dual-channel reads and deadline/reuse PASS"

    10.repeat:
      started := monitor.Latch
      finished := monitor.Latch
      worker := task::
        try:
          started.set true
          adc0.get --samples=1_000_000
        finally:
          critical-do --no-respect-deadline: finished.set true
      started.get
      sleep --ms=1
      worker.cancel
      with-timeout --ms=1000: finished.get
      check-raw (adc0.get --raw)
      check-volts (adc0.get --samples=65)
    print "ADC task cancellation and immediate reuse PASS"
  finally:
    adc1.close
    adc0.close

test-containers:
  ["exit", "stop"].do: |mode/string|
    10.repeat:
      ready := monitor.Latch
      instance := containers.start containers.current {"mode": mode}
          --on-event=:: |event/int value|
            expect-equals containers.Container.EVENT-BACKGROUND-STATE-CHANGE event
            expect-equals true value
            ready.set true
      try:
        if mode == "stop":
          ready.get
          expect-equals "ALREADY_IN_USE" (catch: Adc.channel 0)
          instance.stop
        else:
          expect-equals 0 instance.wait
      finally:
        if not instance.is-closed: instance.stop
      adc := Adc.channel 0
      try:
        check-raw (adc.get --raw)
      finally:
        adc.close
    print "ADC $mode container cleanup/reacquisition PASS"

child args/Map:
  raw-group = native-group
  raw-resource = native-open raw-group 0
  expect-equals null (native-get raw-resource 64)
  if args["mode"] == "stop":
    containers.notify-background-state-changed true
    sleep --ms=60_000
  // Deliberately no close/finalizer: resource-group teardown must reclaim it.

native-group:
  #primitive.adc.init-group
native-open group channel:
  return native-init group channel false 3.8
native-init group channel restricted max:
  #primitive.adc.init
native-get resource samples:
  #primitive.adc.get
native-raw resource:
  #primitive.adc.get-raw
native-cancel resource:
  #primitive.adc.cancel
native-close resource:
  #primitive.adc.close
