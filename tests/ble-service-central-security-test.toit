// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security-owner show Owner
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import .ble-hci-test as fixture
import .ble-service-shutdown-test as security

main:
  with-timeout --ms=10_000:
    ["ready", "authenticated", "unsecured", "failure", "cancel"].do: run it

run mode/string:
  provider := Provider mode
  provider.install
  client := clients.Client
  client.open
  result := monitor.Latch
  ended := monitor.Latch
  responder := task::
    fixture.initialize-replies provider.radio
    fixture.status-reply provider.radio fixture.create-command
    provider.radio.received.add fixture.connection-event
    // The secured link exchanges its MTU before the owner runs.
    fixture.gatt-reply provider.radio #[2, 23, 0] #[3, 23, 0]
    if mode == "ready" or mode == "authenticated":
      provider.entered.get
      provider.radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      fixture.gatt-reply provider.radio #[0x0a, 3, 0] #[0x0b, 42]
      fixture.status-reply provider.radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      provider.radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
  caller := task::
    try:
      error := catch:
        connection := client.connect #[1, 2, 3, 4, 5, 6] --address-type=1
        result.set connection
      if error: result.set error --exception
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    provider.entered.get
    expect (not result.has-value)
    if mode == "cancel": caller.cancel
    else: provider.release.set true
    if mode == "ready" or mode == "authenticated":
      connection/clients.Connection := result.get
      expect provider.owner.encrypted
      snapshot := connection.security
      expect (snapshot.paired and snapshot.encrypted)
      expect-equals (mode == "authenticated") snapshot.authenticated
      expect-equals #[42] (connection.read 3)
      connection.disconnect
      expect (snapshot.paired and snapshot.encrypted)
    else if mode == "unsecured":
      expect-throw "GATT_CENTRAL_SECURITY_NOT_READY": result.get
    else if mode == "failure":
      expect-throw "CENTRAL_POLICY_FAILURE": result.get
    ended.get
    while not provider.radio.closed: sleep --ms=1
    expect provider.owner.closed
    expect (not provider.owner.encrypted)
    expect provider.finished.has-value
  finally:
    provider.release.set true
    caller.cancel
    responder.cancel
    client.close
    provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch
  finished/monitor.Latch ::= monitor.Latch
  owner/security.HeldOwner? := null
  mode_/string

  constructor .mode_:
    super
  open-transport -> transport.Transport: return radio
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    owner = TestOwner host link --authenticated=(mode_ == "authenticated")
    return owner
  run-central-security-owner selected/Owner -> none:
    try:
      entered.set true
      release.get
      if mode_ == "failure": throw "CENTRAL_POLICY_FAILURE"
      if mode_ == "ready" or mode_ == "authenticated":
        while not selected.encrypted: sleep --ms=1
    finally:
      critical-do --no-respect-deadline: finished.set true

class TestOwner extends security.HeldOwner:
  authenticated_/bool
  constructor host/central.Central link/central.Link --authenticated/bool:
    authenticated_ = authenticated
    super host link
  authenticated -> bool: return authenticated_ and encrypted
