// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.privacy
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.api as api
import ble.experimental.service.private-advertising-provider as providers
import ble.experimental.service.provider as rpc
import .ble-hci-test as fixture
import .ble-peripheral-test as peripheral
import .ble-service-advertising-exit-test as exits
import .ble-service-central-cancel-test as shutdown

main:
  with-timeout --ms=10_000:
    expect-throw "INVALID_ARGUMENT": Provider (ByteArray 15)
    expect-throw "INVALID_ARGUMENT": Provider (ByteArray 16) --rotation-interval=(Duration --us=0)
    ["normal", "disable-error", "address-error", "enable-error", "cancel-wait", "cancel-address"].do: run it
    ["waiting", "disable", "address", "enable"].do: client-exit it

// Terminate the application process, bypassing its scoped cleanup. For rotation
// cases the controller has accepted a command but has not replied to it.
client-exit stage/string:
  key := ByteArray 16 --initial=43
  provider := ExitProvider key
  provider.install
  replacement := clients.Client
  replacement.open
  addresses := []
  responder := task::
    radio/fixture.FakeTransport := provider.radio
    fixture.initialize-replies radio
    address-reply radio key addresses
    peripheral.reply radio 0x2006 #[160, 0, 160, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0]
    peripheral.reply radio 0x2008 (ByteArray 32)
    peripheral.reply radio 0x2009 (ByteArray 32)
    peripheral.reply radio 0x200a #[1]
    if stage == "waiting":
      provider.exit-ready.set true
      peripheral.reply radio 0x200a #[0]
    else:
      expect-equals #[1, 10, 32, 1, 0] radio.sent.take
      if stage != "disable":
        radio.received.add #[4, 14, 4, 1, 10, 32, 0]
        packet := radio.sent.take
        expect-equals #[1, 5, 32, 6] packet[..4]
        expect (privacy.resolves key packet[4..] 1)
        expect (packet[4..] != addresses.first)
        if stage == "enable":
          radio.received.add #[4, 14, 4, 1, 5, 32, 0]
          expect-equals #[1, 10, 32, 1, 1] radio.sent.take
      provider.exit-ready.set true
    // Only the replacement transport may receive further commands.
    radio = provider.next-radio
    fixture.initialize-replies radio
    address-reply radio key addresses
    peripheral.reply radio 0x2006 #[160, 0, 160, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0]
    peripheral.reply radio 0x2008 (ByteArray 32)
    peripheral.reply radio 0x2009 (ByteArray 32)
    peripheral.reply radio 0x200a #[1]
    peripheral.reply radio 0x200a #[0]
  try:
    spawn:: exits.application "active"
    provider.radio.closing.get
    expect provider.radio.closed
    expect (not provider.last.is-released)
    submitted := provider.radio.sent-count
    system.process-stats --gc
    expect-throw "GATT_SERVICE_BUSY": replacement.with-advertising #[]: unreachable
    expect-equals 1 provider.opens
    expect-equals submitted provider.radio.sent-count
    provider.radio.release.set true
    while not provider.last.is-released: sleep --ms=1
    replacement.with-advertising #[]: expect-equals 2 provider.opens
    expect provider.next-radio.closed
    expect provider.last.is-released
    expect-equals 2 addresses.size
    expect-equals submitted provider.radio.sent-count
  finally:
    provider.radio.release.set true
    replacement.close
    responder.cancel
    provider.uninstall

class ExitProvider extends providers.Provider:
  radio/shutdown.DelayedTransport ::= shutdown.DelayedTransport
  next-radio/fixture.FakeTransport ::= fixture.FakeTransport
  exit-ready/monitor.Latch ::= monitor.Latch
  last/rpc.Session? := null
  opens/int := 0

  constructor key/ByteArray: super key --rotation-interval=(Duration --ms=500)
  open-transport -> transport.Transport:
    opens++
    return opens == 1 ? radio : next-radio
  create-advertising client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == exits.ARM-EXIT:
      exit-ready.get
      radio.hold = true
      return null
    return super index arguments --gid=gid --client=client

run mode/string:
  key := ByteArray 16: it + 1
  expected-key := key.copy
  provider := Provider key
  key.fill 0
  provider.install
  client := clients.Client
  client.open
  reached := monitor.Latch
  ended := monitor.Latch
  addresses := []
  worker/Task? := null
  responder := task::
    fixture.initialize-replies provider.radio
    address-reply provider.radio expected-key addresses
    peripheral.reply provider.radio 0x2006 #[160, 0, 160, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0]
    peripheral.reply provider.radio 0x2008 (#[3, 2, 1, 6] + (ByteArray 28))
    peripheral.reply provider.radio 0x2009 (ByteArray 32)
    peripheral.reply provider.radio 0x200a #[1]
    if mode == "cancel-wait":
      peripheral.reply provider.radio 0x200a #[0]
    else if mode == "disable-error":
      reject provider.radio 0x200a #[0]
      // Cleanup still attempts to stop an advertiser whose disable was rejected.
      reached.set true
      peripheral.reply provider.radio 0x200a #[0]
    else:
      peripheral.reply provider.radio 0x200a #[0]
      if mode == "address-error" or mode == "cancel-address":
        packet := provider.radio.sent.take
        expect-equals #[1, 5, 32, 6] packet[..4]
        expect (privacy.resolves expected-key packet[4..] 1)
        if mode == "address-error": provider.radio.received.add #[4, 14, 4, 1, 5, 32, 12]
        reached.set true
      else:
        address-reply provider.radio expected-key addresses
        if mode == "enable-error":
          reject provider.radio 0x200a #[1]
          reached.set true
        else:
          peripheral.reply provider.radio 0x200a #[1]
          peripheral.reply provider.radio 0x200a #[0]
          address-reply provider.radio expected-key addresses
          peripheral.reply provider.radio 0x200a #[1]
          reached.set true
          peripheral.reply provider.radio 0x200a #[0]
  try:
    worker = task::
      failure := null
      try:
        failure = catch:
          client.with-advertising #[2, 1, 6]:
            if mode == "cancel-wait": reached.set true
            if mode.starts-with "cancel-": (monitor.Latch).get
            else: reached.get
            system.process-stats --gc
      finally:
        critical-do --no-respect-deadline: ended.set failure
    cancelled-at := 0
    if mode.starts-with "cancel-":
      reached.get
      cancelled-at = Time.monotonic-us
      worker.cancel
    failure := ended.get
    if mode.ends-with "-error": expect (failure is string and failure.contains "status=12")
    else if mode == "cancel-address":
      // The caller stays canceled while the missing command reply still fails
      // the provider under its own bound and remains available to diagnostics.
      expect-null failure
      expect-throw "DEADLINE_EXCEEDED": provider.last.invoke api.ADVERTISING-STOP []
      expect (Time.monotonic-us - cancelled-at < 4_000_000)
    else:
      expect-null failure
      if mode == "cancel-wait": expect (Time.monotonic-us - cancelled-at < 1_000_000)
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals 1 provider.opens
    if mode == "normal": expect-equals 3 addresses.size
    addresses.do: expect (privacy.resolves expected-key it 1)
  finally:
    if worker: worker.cancel
    responder.cancel
    client.close
    provider.uninstall

address-reply radio/fixture.FakeTransport key/ByteArray addresses/List:
  packet := radio.sent.take
  expect-equals #[1, 5, 32, 6] packet[..4]
  address := packet[4..].copy
  expect (privacy.resolves key address 1)
  if not addresses.is-empty: expect (address != addresses.last)
  addresses.add address
  system.process-stats --gc
  radio.received.add #[4, 14, 4, 1, 5, 32, 0]

reject radio/fixture.FakeTransport opcode/int parameters/ByteArray:
  expect-equals (#[1, opcode & 255, opcode >> 8, parameters.size] + parameters) radio.sent.take
  radio.received.add #[4, 14, 4, 1, opcode & 255, opcode >> 8, 12]

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  last/rpc.Session? := null
  opens/int := 0

  constructor key/ByteArray --rotation-interval/Duration=(Duration --ms=50):
    super key --rotation-interval=rotation-interval
  open-transport -> transport.Transport:
    opens++
    return radio
  create-advertising client/int arguments/List -> rpc.Session:
    last = super client arguments
    return last
