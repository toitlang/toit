// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.advertising-provider as providers
import ble.experimental.service.provider as rpc
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=10_000:
    ["normal", "scannable", "throw", "cancel", "disable-error", "enable-error", "cancel-start", "cancel-enable"].do: run it

run mode/string:
  provider := Provider
  provider.install
  client := clients.Client
  other := clients.Client
  client.open
  other.open
  entered := monitor.Latch
  ended := monitor.Latch
  worker/Task? := null
  response := mode == "scannable" ? #[2, 9, 'x'] : #[]
  responder := task::
    if mode == "cancel-start":
      // Cancel while initialization runs. Every command is answered promptly;
      // the cancelled worker leaves at the checkpoint after whichever command
      // it was in and its cleanup commands are answered too.
      entered.set true
      // The cancelled worker closes the radio at some point in this script.
      catch --unwind=(: it != "FAKE_CLOSED"):
        fixture.initialize-replies provider.radio
        while true:
          packet := provider.radio.sent.take
          provider.radio.received.add #[4, 14, 4, 1, packet[1], packet[2], 0]
    else:
      fixture.initialize-replies provider.radio
      // Assert the wire encoding independently of the production encoder.
      peripheral.reply provider.radio 0x2006
          #[0xa0, 0, 0xa0, 0, mode == "scannable" ? 2 : 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
      peripheral.reply provider.radio 0x2008 (#[3, 2, 1, 6] + (ByteArray 28))
      peripheral.reply provider.radio 0x2009 (#[response.size] + response + (ByteArray (31 - response.size)))
      if mode == "cancel-enable":
        expect-equals #[1, 10, 32, 1, 1] provider.radio.sent.take
        entered.set true
        provider.radio.received.add #[4, 14, 4, 1, 10, 32, 0]
        // Cleanup after the cancellation disables advertising.
        peripheral.reply provider.radio 0x200a #[0]
      else if mode == "enable-error":
        expect-equals #[1, 10, 32, 1, 1] provider.radio.sent.take
        provider.radio.received.add #[4, 14, 4, 1, 10, 32, 12]
      else:
        peripheral.reply provider.radio 0x200a #[1]
        if mode == "disable-error":
          expect-equals #[1, 10, 32, 1, 0] provider.radio.sent.take
          provider.radio.received.add #[4, 14, 4, 1, 10, 32, 12]
        else:
          peripheral.reply provider.radio 0x200a #[0]
  try:
    caps := client.capabilities
    expect caps.advertising
    expect (not caps.scanning and not caps.gatt-peripheral and not caps.gatt-central)
    expect-equals 0 caps.max-value-size
    expect-throw "INVALID_ARGUMENT": client.with-advertising (ByteArray 32): unreachable
    expect-throw "INVALID_ARGUMENT": client.with-advertising #[] --interval=31: unreachable
    expect-throw "INVALID_ARGUMENT": client.with-advertising #[] --scan-response=#[0]: unreachable
    expect-equals 0 provider.opens
    worker = task::
      failure := null
      try:
        failure = catch:
          client.with-advertising #[2, 1, 6] --scan-response=response --scannable=(mode == "scannable"):
            expect (mode != "enable-error")
            expect-throw "GATT_SERVICE_BUSY": other.with-advertising #[]: unreachable
            expect other.capabilities.advertising
            system.process-stats --gc
            entered.set true
            if mode == "throw": throw "APPLICATION_FAILED"
            if mode == "cancel": (monitor.Latch).get
      finally:
        critical-do --no-respect-deadline: ended.set failure
    cancelled-at := 0
    if mode == "cancel" or mode == "cancel-start" or mode == "cancel-enable":
      entered.get
      cancelled-at = Time.monotonic-us
      worker.cancel
    failure := ended.get
    if mode == "cancel-start" or mode == "cancel-enable":
      expect (Time.monotonic-us - cancelled-at < 1_000_000)
    if mode == "throw": expect-equals "APPLICATION_FAILED" failure
    else if mode == "disable-error" or mode == "enable-error":
      expect (failure is string and failure.contains "status=12")
    else: expect-null failure
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
    // Reuse the installed provider from another client after every exit path.
    // A closed transport alone does not prove its service reservation is free.
    responder.cancel
    provider.radio = fixture.FakeTransport
    responder = task::
      fixture.initialize-replies provider.radio
      peripheral.reply provider.radio 0x2006
          #[0xa0, 0, 0xa0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
      peripheral.reply provider.radio 0x2008 (#[3, 2, 1, 6] + (ByteArray 28))
      peripheral.reply provider.radio 0x2009 (ByteArray 32)
      peripheral.reply provider.radio 0x200a #[1]
      peripheral.reply provider.radio 0x200a #[0]
    replacement := other.start-advertising #[2, 1, 6]
    try:
      expect-equals 2 provider.opens
      expect (not provider.radio.closed)
      expect-throw "GATT_SERVICE_BUSY": client.with-advertising #[]: unreachable
    finally:
      replacement.stop
    expect replacement.is-closed
    replacement.stop
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
  finally:
    if worker: worker.cancel
    client.close
    other.close
    responder.cancel
    provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport := fixture.FakeTransport
  last/rpc.Session? := null
  opens/int := 0

  constructor: super
  open-transport -> transport.Transport:
    opens++
    return radio
  create-advertising client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last
