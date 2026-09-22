// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner show Owner
import ble.experimental.signaling
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import .ble-fixture as fixture
import .ble-key-reply-test as keys

main:
  with-timeout --ms=5_000:
    provider := Provider
    provider.install
    client := clients.Client
    client.open
    try:
      session := client.configure
      session.start #[2, 1, 6]
      // Initialization is waiting on this command when the client closes.
      expect-equals #[1, 3, 12, 0] provider.radio.sent.take
      session.close
      provider.radio.closing.get
      expect provider.radio.closed
      expect (not provider.last.is-released)
      expect-throw "GATT_SERVICE_BUSY": client.configure
      provider.radio.release.set true
      while not provider.last.is-released: sleep --ms=1
      next := client.configure
      next.close
      expect provider.last.is-released
    finally:
      provider.radio.release.set true
      client.close
      provider.uninstall
    security-cleanup
    security-failure

security-failure:
  provider := SecurityProvider --failure
  provider.install
  client := clients.Client
  client.open
  responder := task::
    fixture.initialize-replies provider.radio
    keys.establish provider.radio
    fixture.att-sent provider.radio (signaling.parameter-request 1) --channel=5
  try:
    session := client.configure
    session.start #[2, 1, 6]
    provider.entered.get
    session.peer
    provider.radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    while not provider.owner.encrypted: sleep --ms=1
    provider.release.set true
    // Keep the RPC client open and issue no mailbox request. The service must
    // terminate the failed link itself, without relying on client cleanup.
    with-timeout --ms=500:
      while not provider.radio.closed: sleep --ms=1
    expect provider.owner.closed
    expect (not provider.owner.encrypted)
    expect-equals "STORAGE_TEST_FAILURE" (catch: session.next)
  finally:
    provider.release.set true
    client.close
    responder.cancel
    provider.uninstall

security-cleanup:
  provider := SecurityProvider
  provider.install
  first := clients.Client
  second := clients.Client
  first.open
  second.open
  responder := task::
    fixture.initialize-replies provider.radio
    keys.establish provider.radio
    fixture.att-sent provider.radio (signaling.parameter-request 1) --channel=5
  try:
    session := first.configure
    session.start #[2, 1, 6]
    provider.entered.get
    // Simulate client exit while provider-side security/storage cleanup is
    // still using session state. The other RPC client must not take ownership.
    first.close
    provider.cleaning.get
    expect provider.owner.closed
    expect (not provider.last.is-released)
    expect-throw "GATT_SERVICE_BUSY": second.configure
    provider.release.set true
    while not provider.last.is-released: sleep --ms=1
    expect provider.finished.has-value
    next := second.configure
    next.close
    expect provider.last.is-released
  finally:
    provider.release.set true
    first.close
    second.close
    responder.cancel
    provider.uninstall

class SecurityProvider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  entered/monitor.Latch ::= monitor.Latch
  cleaning/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  finished/monitor.Latch ::= monitor.Latch
  owner/HeldOwner? := null
  last/rpc.Session? := null
  failure_/bool

  constructor --failure/bool=false:
    failure_ = failure
    super

  create-builder client/int name/string -> rpc.Session:
    last = super client name
    return last

  open-transport -> transport.Transport: return radio

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    owner = HeldOwner host link
    return owner

  run-security-owner owner/Owner -> none:
    if failure_:
      entered.set true
      release.get
      throw "STORAGE_TEST_FAILURE"
    try:
      entered.set true
      (monitor.Latch).get
    finally:
      critical-do --no-respect-deadline:
        cleaning.set true
        release.get
        finished.set true

class HeldOwner implements Owner:
  host_/central.Central
  link_/central.Link
  closed/bool := false

  constructor .host_ .link_:
  matches host/central.Central link/central.Link -> bool: return host == host_ and link == link_
  paired -> bool: return encrypted
  encrypted -> bool: return not closed and link_.encrypted
  authenticated -> bool: return false
  receive bytes/ByteArray -> none: unreachable
  close -> none: closed = true

class DelayedTransport extends fixture.FakeTransport:
  closing/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch

  receive -> ByteArray:
    try:
      return super
    finally:
      // Native close can wake a reader before its final cleanup has run.
      critical-do --no-respect-deadline:
        closing.set true
        release.get

class Provider extends providers.Provider:
  radio/DelayedTransport ::= DelayedTransport
  last/rpc.Session? := null

  constructor:
    super

  create-builder client/int name/string -> rpc.Session:
    last = super client name
    return last

  open-transport -> transport.Transport: return radio
