// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.service.client as clients
import ble.experimental.service.api as api
import .ble-service-advertising-test as advertising
import .ble-service-private-advertising-test as private-fixture
import .ble-fixture as fixture
import .ble-peripheral-test as peripheral

main:
  with-timeout --ms=30_000:
    ["normal", "empty", "non-scannable", "busy", "cancel", "first-error", "second-error", "lost-second"].do: run it
    test-rotation
    ["normal", "throw", "return", "stop"].do: test-scope it

encoded value/ByteArray -> ByteArray: return #[value.size] + value + (ByteArray (31 - value.size))

run mode/string:
  provider := Provider
  provider.install
  client := clients.Client
  other := clients.Client
  client.open
  other.open
  started := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  scannable := mode != "non-scannable"
  data := mode == "empty" ? #[] : (ByteArray 31: it)
  response := scannable and mode != "empty" ? (ByteArray 31: 31 - it) : #[]
  expected-data := encoded data
  expected-response := encoded response
  session/clients.Advertising? := null
  updater/Task? := null
  responder := task::
    fixture.initialize-replies provider.radio
    peripheral.reply provider.radio 0x2006
        #[0xa0, 0, 0xa0, 0, scannable ? 2 : 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
    peripheral.reply provider.radio 0x2008 (encoded #[2, 1, 6])
    peripheral.reply provider.radio 0x2009 (encoded #[])
    peripheral.reply provider.radio 0x200a #[1]
    expect-equals (#[1, 8, 32, 32] + expected-data) provider.radio.sent.take
    started.set true
    release.get
    provider.radio.received.add #[4, 14, 4, 1, 8, 32, mode == "first-error" ? 12 : 0]
    if mode != "first-error" and mode != "cancel":
      expect-equals (#[1, 9, 32, 32] + expected-response) provider.radio.sent.take
      if mode != "lost-second":
        provider.radio.received.add #[4, 14, 4, 1, 9, 32, mode == "second-error" ? 12 : 0]
    if mode == "lost-second":
      while not provider.radio.closed: sleep --ms=1
    else:
      peripheral.reply provider.radio 0x200a #[0]
  try:
    session = client.start-advertising #[2, 1, 6] --scannable=scannable
    expect-throw "INVALID_ARGUMENT": session.update (ByteArray 32)
    expect-throw "INVALID_ARGUMENT": session.update #[] --scan-response=(ByteArray 32)
    if not scannable:
      expect-throw "INVALID_ARGUMENT": session.update #[] --scan-response=#[1]
      expect (not session.is-closed)
    updater = task::
      failure := null
      completed := false
      try:
        failure = catch:
          session.update data --scan-response=response
          completed = true
      finally:
        critical-do: ended.set [failure, completed]
    started.get
    data.fill 99
    response.fill 98
    system.process-stats --gc
    if mode == "busy":
      expect-throw "BLE_ADVERTISING_UPDATE_BUSY": session.update #[1]
      expect (not session.is-closed)
      expect-throw "GATT_SERVICE_BUSY": other.start-advertising #[]
      expect other.capabilities.advertising
    if mode == "cancel":
      updater.cancel
      // Observe the stop RPC before releasing the pending command, without a
      // scheduler-delay assumption. Its handler stops before waiting for exit.
      provider.stop-entered.get
    release.set true
    result := ended.get
    if mode == "first-error" or mode == "second-error":
      expect (result[0] is string and result[0].contains "status=12")
      expect session.is-closed
    else if mode == "lost-second":
      // The unanswered command's bound is the engine's, not the worker's.
      expect-equals "HCI_COMMAND_ABORTED" result[0]
      expect session.is-closed
    else if mode == "cancel":
      expect-null result[0]
      expect (not result[1])
      expect session.is-closed
    else:
      expect-null result[0]
      expect result[1]
      expect (not session.is-closed)
      expect-equals 1 provider.opens
      expect (not provider.radio.closed)
    session.stop
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-throw "BLE_ADVERTISING_CLOSED": session.update #[]
    responder.cancel
    provider.radio = fixture.FakeTransport
    responder = task::
      fixture.initialize-replies provider.radio
      peripheral.reply provider.radio 0x2006 #[160, 0, 160, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
      peripheral.reply provider.radio 0x2008 (encoded #[])
      peripheral.reply provider.radio 0x2009 (encoded #[])
      peripheral.reply provider.radio 0x200a #[1]
      peripheral.reply provider.radio 0x200a #[0]
    replacement := other.start-advertising #[]
    try:
      expect-equals 2 provider.opens
    finally:
      replacement.stop
    while not provider.last.is-released: sleep --ms=1
  finally:
    if updater: updater.cancel
    if session: session.close
    client.close
    other.close
    responder.cancel
    provider.uninstall

class Provider extends advertising.Provider:
  stop-entered/monitor.Latch ::= monitor.Latch
  constructor: super

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ADVERTISING-STOP: stop-entered.set true
    return super index arguments --gid=gid --client=client

test-rotation:
  key := ByteArray 16 --initial=42
  provider := PrivateProvider key
  provider.install
  client := clients.Client
  client.open
  rotating := monitor.Latch
  release := monitor.Latch
  finished := monitor.Latch
  addresses := []
  session/clients.Advertising? := null
  updater/Task? := null
  responder := task::
    fixture.initialize-replies provider.radio
    private-fixture.address-reply provider.radio key addresses
    peripheral.reply provider.radio 0x2006 #[160, 0, 160, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0]
    peripheral.reply provider.radio 0x2008 (encoded #[2, 1, 6])
    peripheral.reply provider.radio 0x2009 (encoded #[])
    peripheral.reply provider.radio 0x200a #[1]
    peripheral.reply provider.radio 0x200a #[0]
    rotating.set true
    release.get
    private-fixture.address-reply provider.radio key addresses
    peripheral.reply provider.radio 0x200a #[1]
    // The update cannot interleave with disable/address/enable.
    peripheral.reply provider.radio 0x2008 (encoded #[2, 1, 5])
    peripheral.reply provider.radio 0x2009 (encoded #[])
    peripheral.reply provider.radio 0x200a #[0]
  try:
    session = client.start-advertising #[2, 1, 6]
    rotating.get
    updater = task::
      failure := catch: session.update #[2, 1, 5]
      finished.set failure --exception=(failure != null)
    provider.update-entered.get
    system.process-stats --gc
    release.set true
    finished.get
    session.stop
    while not provider.last.is-released: sleep --ms=1
    expect-equals 2 addresses.size
    expect-equals 1 provider.opens
    expect provider.radio.closed
  finally:
    if updater: updater.cancel
    if session: session.close
    responder.cancel
    client.close
    provider.uninstall

class PrivateProvider extends private-fixture.Provider:
  update-entered/monitor.Latch ::= monitor.Latch
  constructor key/ByteArray: super key --rotation-interval=(Duration --ms=500)

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ADVERTISING-UPDATE: update-entered.set true
    return super index arguments --gid=gid --client=client

test-scope mode/string:
  provider := advertising.Provider
  provider.install
  client := clients.Client
  client.open
  held := []
  responder := task::
    fixture.initialize-replies provider.radio
    peripheral.reply provider.radio 0x2006 #[160, 0, 160, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0]
    peripheral.reply provider.radio 0x2008 (encoded #[2, 1, 6])
    peripheral.reply provider.radio 0x2009 (encoded #[])
    peripheral.reply provider.radio 0x200a #[1]
    peripheral.reply provider.radio 0x2008 (encoded #[2, 1, 5])
    peripheral.reply provider.radio 0x2009 (encoded #[])
    peripheral.reply provider.radio 0x200a #[0]
  try:
    result := null
    error := catch: result = scoped-update client held mode
    if mode == "throw":
      expect-equals "SCOPE_BODY_FAILED" error
    else:
      expect-null error
      expect-equals (mode == "return" ? "NON_LOCAL_RETURN" : "UPDATED") result
    expect-equals 1 held.size
    advertiser/clients.Advertising := held[0]
    expect advertiser.is-closed
    expect-throw "BLE_ADVERTISING_CLOSED": advertiser.update #[]
    while not provider.last.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals 1 provider.opens
  finally:
    responder.cancel
    client.close
    provider.uninstall

scoped-update client/clients.Client held/List mode/string -> string:
  return client.with-advertising #[2, 1, 6]: | advertiser/clients.Advertising |
    held.add advertiser
    expect (not advertiser.is-closed)
    advertiser.update #[2, 1, 5]
    system.process-stats --gc
    if mode == "throw": throw "SCOPE_BODY_FAILED"
    if mode == "return": return "NON_LOCAL_RETURN"
    if mode == "stop": advertiser.stop
    "UPDATED"
