// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as gatt
import ble.experimental.service.provider as rpc
import .ble-service-mixed-test as mixed
import .ble-service-multiclient-test as wire
import .ble-connect-isolation-test as connect
import .ble-multilink-test as links
import .ble-bounded-accept-test as accept
import .ble-accept-update-test as updates
import .ble-hci-test as fixture
import .ble-peripheral-test as legacy

ARM-EXIT ::= 1000

main:
  with-timeout --ms=30_000:
    [false, true].do: | second/bool |
      ["expired", "won", "lost"].do: run second it

run second/bool mode/string:
  provider := Provider
  provider.install
  central-client := clients.Client
  replacement := clients.Client
  central-client.open
  replacement.open
  release := monitor.Latch
  reused := monitor.Latch
  closed-replacement := monitor.Latch
  finished := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      mixed.initialize radio
      owner/central.Central := provider.ready.get
      connect.establish radio owner 1 0x234 --extended-mode
      accept.setup radio
      accept.enabled radio
      if second: legacy.reply radio 0x2037 (updates.encode #[42] true)
      opcode := second ? 0x2038 : 0x2037
      expect-equals (hci.command-packet opcode (updates.encode #[42] true)) radio.sent.take
      provider.held.set true
      // The remaining link must carry traffic even before the held reply is
      // released, while client death is waiting for bounded accept cleanup.
      wire.sent radio 0x234 #[0x0a, 3, 0]
      wire.incoming radio 0x234 #[0x0b, 0xa1]
      release.get
      if mode == "lost":
        while not radio.closed: sleep --ms=1
      else:
        updates.reply radio opcode
        if mode == "won": accept.connected radio
        accept.terminal radio --won=(mode == "won")
        // A second payload command here would violate cancellation ordering.
        accept.remove radio
        if mode == "won": wire.disconnect radio 0x235
        wire.sent radio 0x234 #[0x0a, 3, 0]
        wire.incoming radio 0x234 #[0x0b, 0xa2]
        accept.setup radio
        accept.enabled radio
        reused.set true
        closed-replacement.get
        accept.terminal radio
        accept.remove radio
        wire.sent radio 0x234 #[0x0a, 3, 0]
        wire.incoming radio 0x234 #[0x0b, 0xa3]
        wire.disconnect radio 0x234
    finally:
      critical-do --no-respect-deadline: finished.set true
  try:
    survivor := central-client.connect (links.address 1) --address-type=1
    spawn:: application
    provider.closed.get
    old := provider.last
    expect old.closed-with-update
    expect (not old.is-released)
    expect (not provider.radio.closed)
    expect-throw "GATT_SERVICE_BUSY": replacement.configure
    retained := survivor.read 3
    expect-equals #[0xa1] retained
    system.process-stats --gc
    submitted := provider.radio.sent-count
    release.set true
    old.update-ended.get
    expect (not old.updating)
    if mode == "lost":
      while not provider.radio.closed: sleep --ms=1
      error := catch: survivor.read 3
      expect (["HCI_CLOSED", "HCI_COMMAND_ABORTED", "DEADLINE_EXCEEDED", "ATT_CLOSED"].contains error)
      expect-equals 1 provider.opens
      expect-equals submitted provider.radio.sent-count
      survivor.disconnect
    else:
      while not old.is-released: sleep --ms=1
      expect-equals #[0xa2] (survivor.read 3)
      next := replacement.configure
      next.start #[2, 1, 6]
      reused.get
      next.close
      closed-replacement.set true
      while not provider.last.is-released: sleep --ms=1
      expect-equals #[0xa3] (survivor.read 3)
      expect (not provider.radio.closed)
      survivor.disconnect
    finished.get
    expect-equals #[0xa1] retained
    expect provider.radio.closed
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
  finally:
    release.set true
    closed-replacement.set true
    central-client.close
    replacement.close
    responder.cancel
    provider.uninstall

application:
  client := ExitClient
  client.open
  try:
    session := client.configure
    session.start #[2, 1, 6]
    task::
      session.update-advertising #[42] --scan-response=#[42]
      throw "UNEXPECTED_MIXED_UPDATE_REPLY"
    client.arm-exit
    exit 0
  finally:
    print "UNEXPECTED_MIXED_UPDATE_FINALLY"

class ExitClient extends clients.Client:
  constructor: super
  arm-exit -> none: invoke_ ARM-EXIT null

class Provider extends mixed.Provider:
  held/monitor.Latch ::= monitor.Latch
  closed/monitor.Latch ::= monitor.Latch
  last/Session? := null
  constructor: super
  create-builder client/int name/string -> rpc.Session:
    last = Session this client name
    return last
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ARM-EXIT:
      held.get
      expect last.updating
      return null
    return super index arguments --gid=gid --client=client

class Session extends gatt.Session:
  provider_/Provider
  updating/bool := false
  closed-with-update/bool := false
  update-ended/monitor.Latch ::= monitor.Latch
  constructor .provider_ client/int name/string:
    super provider_ client --name=name
  invoke index/int arguments/List -> any:
    if index != api.PERIPHERAL-ADVERTISING-UPDATE: return super index arguments
    updating = true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline:
        updating = false
        update-ended.set true
  on-closed -> none:
    closed-with-update = updating
    provider_.closed.set true
    super
