// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.bounded-central as bounded
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.provider as rpc
import ble.experimental.service.shared-host as shared
import expect show *
import monitor
import .ble-bounded-accept-test as accept
import .ble-connect-isolation-test as connect
import .ble-hci-test as fixture
import .ble-multilink-test as links
import .ble-security-cleanup-test as cleanup
import .ble-service-multiclient-test as wire

main:
  ["normal", "first", "waiting", "pending", "won", "security", "hook"].do: | mode/string |
    with-timeout --ms=10_000: run mode
  with-timeout --ms=5_000: final-close-failure

final-close-failure:
  provider := Provider "normal"
  provider.radio.fail-close = true
  provider.install
  client := clients.Client
  client.open
  responder := task::
    fixture.initialize-replies provider.radio
    accept.setup provider.radio
    accept.enabled provider.radio
    accept.connected provider.radio
    accept.terminal provider.radio --won
    accept.remove provider.radio
    provider.radio.sent.take  // Parameter request.
    links.completed provider.radio 0x235
    wire.disconnect provider.radio 0x235
  try:
    session := client.session
    session.peer
    session.close
    while provider.radio.closes == 0: sleep --ms=1
    yield
    expect (not provider.last.is-released)
    expect-throw "GATT_SERVICE_BUSY": client.configure
    catch: session.close
    expect (not provider.last.is-released)
    expect-equals 1 provider.radio.closes
  finally:
    client.close
    provider.uninstall
    responder.cancel

run mode/string:
  provider := Provider mode
  provider.install
  client := clients.Client
  client.open
  // A directly reserved central lifetime is deliberately outside RPC admission.
  // This tests the real peripheral session through RPC without enabling mixed
  // admission before its independent policy/security tests exist.
  pool := provider.reserve-shared-host
  seen := monitor.Latch
  release := monitor.Latch
  responder := task::
    fixture.initialize-replies provider.radio
    owner/central.Central := provider.ready.get
    if mode != "first": connect.establish provider.radio owner 1 0x234 --extended-mode
    if mode != "waiting":
      accept.setup provider.radio
      accept.enabled provider.radio
    if ["normal", "first", "security", "hook"].contains mode:
      accept.connected provider.radio
      accept.terminal provider.radio --won
      accept.remove provider.radio
      if mode != "security":
        packet := provider.radio.sent.take
        expect-equals #[2, 0x35, 2] packet[..3]
        expect-equals #[5, 0] packet[7..9]
        links.completed provider.radio 0x235
    if mode == "first": connect.establish provider.radio owner 1 0x234 --extended-mode
    seen.set true
    release.get
    if mode == "pending" or mode == "won":
      if mode == "won": accept.connected provider.radio
      accept.terminal provider.radio --won=(mode == "won")
      accept.remove provider.radio
    if mode != "pending" and mode != "waiting": wire.disconnect provider.radio 0x235
    wire.sent provider.radio 0x234 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x234 #[0x0b, 42]
    // Reuse the released peripheral reservation and handle on the same owner.
    accept.setup provider.radio
    accept.enabled provider.radio
    accept.connected provider.radio
    accept.terminal provider.radio --won
    accept.remove provider.radio
    packet := provider.radio.sent.take
    expect-equals #[2, 0x35, 2] packet[..3]
    expect-equals #[5, 0] packet[7..9]
    links.completed provider.radio 0x235
    wire.disconnect provider.radio 0x235
    wire.disconnect provider.radio 0x234
  att-client/att.Client? := null
  survivor/central.Link? := null
  holder/Task? := null
  held := monitor.Latch
  holder-ended := monitor.Latch
  try:
    session/clients.Session? := null
    if mode == "first":
      session = client.session
      session.peer
    pool.setup: | owner/central.Central info/hci.Capabilities |
      survivor = owner.connect (links.address 1) --address-type=1
      att-client = att.Client owner survivor
    if mode == "waiting":
      holder = task::
        try:
          pool.setup: | owner/central.Central info/hci.Capabilities |
            held.set true
            release.get
        finally:
          critical-do --no-respect-deadline: holder-ended.set true
      held.get
    if not session: session = client.session
    seen.get
    if mode == "normal" or mode == "hook": session.peer
    if mode == "security": expect-throw "PERIPHERAL_SECURITY_FAILED": session.peer
    close-error := catch: session.close
    if close-error:
      expect-equals "hook" mode
      expect-equals "SECURITY_CLOSE_FAILED" close-error
    yield
    if mode == "waiting":
      while not provider.last.is-released: sleep --ms=1
      expect (not holder-ended.has-value)
    else:
      expect (not provider.last.is-released)
    expect (not provider.radio.closed)
    release.set true
    if holder: holder-ended.get
    while not provider.last.is-released: sleep --ms=1
    expect (not provider.radio.closed)
    expect-equals #[42] (att-client.read 3)
    if mode == "hook": expect-equals 1 provider.hook.closes
    provider.fail-security = false
    provider.hook = null
    next := client.session
    next.peer
    next.close
    while not provider.last.is-released: sleep --ms=1
    expect (not provider.radio.closed)
    expect-equals 1 provider.opens
    att-client.close
    att-client.wait-closed
    catch: survivor.wait-disconnected
    expect survivor.has-ended
    pool.release
    expect provider.radio.closed
    expect pool.released
    expect-equals 1 provider.radio.closes
  finally:
    release.set true
    if holder: holder.cancel
    client.close
    if att-client: att-client.close
    pool.fail
    provider.uninstall
    responder.cancel

class Radio extends fixture.FakeTransport:
  closes/int := 0
  fail-close/bool := false
  close -> none:
    closes++
    if fail-close: throw "TRANSPORT_CLOSE_FAILED"
    super

class Provider extends providers.Provider:
  radio/Radio ::= Radio
  ready/monitor.Latch ::= monitor.Latch
  opens/int := 0
  last/rpc.Session? := null
  fail-security/bool := ?
  hook/cleanup.Owner? := null

  constructor mode/string:
    fail-security = mode == "security"
    if mode == "hook": hook = cleanup.Owner true
    super

  open-transport -> Radio:
    opens++
    return radio

  reserve-peripheral-host -> shared.Host?: return reserve-shared-host

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    host := bounded.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=receive-limit
        --link-limit=2
    ready.set host
    return host

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> security-owner.Owner?:
    if fail-security: throw "PERIPHERAL_SECURITY_FAILED"
    return hook

  run-security-owner owner/security-owner.Owner -> none:
    (monitor.Latch).get

  create-session client/int -> rpc.Session:
    last = super client
    return last
