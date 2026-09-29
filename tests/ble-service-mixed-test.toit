// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.service.client as clients
import ble.experimental.service.api
import ble.experimental.service.gatt-provider as mixed
import ble.experimental.service.provider as rpc
import expect show *
import io
import monitor
import system
import .ble-bounded-accept-test as accept
import .ble-connect-isolation-test as connect
import .ble-fixture as fixture
import .ble-multilink-test as links
import .ble-service-multiclient-test as wire

main:
  admission
  [false, true].do: | peripheral-first/bool |
    [false, true].do: | close-central/bool |
      with-timeout --ms=10_000: run peripheral-first close-central
  [0, 1].do: | missing/int |
    with-timeout --ms=5_000: unsupported missing
  with-timeout --ms=5_000: two-central
  ["completion", "early-disconnect", "pending-read"].do: | mode/string |
    with-timeout --ms=10_000: failed-central mode
  [false, true].do: | won/bool |
    with-timeout --ms=5_000: pending won
    with-timeout --ms=5_000: pending-central won

// Mirrors a failed establishment and the successful-completion/0x3e disconnect
// sequence seen on S3. The peripheral survives while the central slot is reused.
failed-central mode/string:
  provider := Provider
  provider.install
  a := clients.Client
  b := clients.Client
  replacement := clients.Client
  a.open
  b.open
  replacement.open
  cycles := mode == "pending-read" ? 12 : 1
  survived := List cycles: monitor.Latch
  exchanged := List cycles: monitor.Latch
  done := monitor.Latch
  responder := task::
    radio := provider.radio
    initialize radio
    owner/central.Central := provider.ready.get
    peripheral radio
    cycles.repeat: | cycle/int |
      fixture.status-reply radio
          hci.command-packet owner.connection-opcode
              owner.encode-connection (links.address 2) --address-type=1 --own-address-type=0
      event := connect.completed-connection 2 0x234
      if mode == "completion": event[4] = 0x3e
      radio.received.add event
      if mode != "completion":
        if mode == "pending-read":
          // Leave this packet uncompleted. Twelve failures exceed the eight
          // controller credits; survivor traffic must prove their reclamation.
          expect-equals #[2, 0x34, 2, 7, 0, 3, 0, 4, 0, 0x0a, 3, 0] radio.sent.take
        radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x3e]
      read-peripheral radio
      (survived[cycle] as monitor.Latch).set true
      connect.establish radio owner 3 0x234 --extended-mode
      wire.sent radio 0x234 #[0x0a, 3, 0]
      wire.incoming radio 0x234 #[0x0b, 43 + cycle]
      read-peripheral radio
      (exchanged[cycle] as monitor.Latch).set true
      wire.disconnect radio 0x234
    wire.disconnect radio 0x235
    done.set true
  try:
    survivor := a.session
    survivor.peer
    retained := survivor.value 3
    expect-equals "Toit".to-byte-array retained
    cycles.repeat: | cycle/int |
      failed/clients.Connection? := null
      if mode == "pending-read":
        failed = b.connect (links.address 2) --address-type=1
        expect-throw "HCI_LINK_DISCONNECTED": failed.read 3
        failed.disconnect
      else if mode == "completion":
        expect-throw "HCI_CONNECTION_FAILED status=62": b.connect (links.address 2) --address-type=1
      else:
        error := catch: failed = b.connect (links.address 2) --address-type=1
        // The provider's ConnectionLost crosses RPC as its string form.
        if error: expect (error.stringify.starts-with "HCI_CONNECTION_LOST")
        else:
          // Completion can reach RPC before the following disconnect. Once
          // survivor traffic proves that event was dispatched, reads must fail.
          (survived[cycle] as monitor.Latch).get
          error = catch: failed.read 3
          expect (["HCI_LINK_DISCONNECTED", "ATT_CLOSED"].contains error)
          failed.disconnect
      old := provider.last-central
      while not old.is-released: sleep --ms=1
      (survived[cycle] as monitor.Latch).get
      expect (not provider.radio.closed)
      expect (not provider.last-peripheral.is-closed)
      system.process-stats --gc
      expect-equals "Toit".to-byte-array retained
      next := replacement.connect (links.address 3) --address-type=1
      expect-equals #[43 + cycle] (next.read 3)
      if failed:
        expect-throw "GATT_CONNECTION_CLOSED": failed.read 3
      (exchanged[cycle] as monitor.Latch).get
      next.disconnect
      while not provider.last-central.is-released: sleep --ms=1
    survivor.close
    done.get
    while not provider.last-peripheral.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
  finally:
    a.close
    b.close
    replacement.close
    provider.uninstall
    responder.cancel

// Client closure during Command Status must join cancellation or a winning
// connection before admitting a replacement, preserving the peripheral link.
pending-central won/bool:
  provider := OneEachProvider
  provider.install
  a := clients.Client
  b := clients.Client
  replacement := clients.Client
  a.open
  b.open
  replacement.open
  seen := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  survivor-read := monitor.Latch
  done := monitor.Latch
  returned := false
  caller/Task? := null
  responder := task::
    radio := provider.radio
    initialize radio
    owner/central.Central := provider.ready.get
    peripheral radio
    expect-equals (hci.command-packet owner.connection-opcode
        (owner.encode-connection (links.address 2) --address-type=1 --own-address-type=0)) radio.sent.take
    seen.set true
    while not provider.last-central.is-closed: yield
    radio.received.add #[4, 15, 4, 0, 1, 0x43, 0x20]
    expect-equals #[1, 0x0e, 0x20, 0] radio.sent.take
    release.get
    radio.received.add #[4, 14, 4, 1, 0x0e, 0x20, 0]
    event := connect.completed-connection 2 0x234
    if not won: event[4] = 2
    radio.received.add event
    if won: wire.disconnect radio 0x234
    read-peripheral radio
    survivor-read.set true
    connect.establish radio owner 3 0x234 --extended-mode
    wire.sent radio 0x234 #[0x0a, 3, 0]
    wire.incoming radio 0x234 #[0x0b, 43]
    wire.disconnect radio 0x234
    read-peripheral radio
    wire.disconnect radio 0x235
    done.set true
  try:
    survivor := a.session
    survivor.peer
    caller = task::
      try:
        catch:
          b.connect (links.address 2) --address-type=1
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    seen.get
    b.close
    old := provider.last-central
    expect (not old.is-released)
    expect (not provider.radio.closed)
    expect-throw "GATT_SERVICE_BUSY": replacement.connect (links.address 3) --address-type=1
    system.process-stats --gc
    release.set true
    ended.get
    while not old.is-released: sleep --ms=1
    expect (not returned)
    survivor-read.get
    next := replacement.connect (links.address 3) --address-type=1
    expect-equals #[43] (next.read 3)
    next.disconnect
    survivor.close
    done.get
    while not provider.last-peripheral.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
  finally:
    release.set true
    if caller: caller.cancel
    a.close
    b.close
    replacement.close
    provider.uninstall
    responder.cancel

two-central:
  provider := Provider
  provider.install
  a := clients.Client
  b := clients.Client
  a.open
  b.open
  responder := task::
    initialize provider.radio
    owner/central.Central := provider.ready.get
    connect.establish provider.radio owner 1 0x234 --extended-mode
    connect.establish provider.radio owner 2 0x235 --extended-mode
    wire.sent provider.radio 0x234 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x234 #[0x0b, 41]
    wire.sent provider.radio 0x235 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x235 #[0x0b, 42]
    wire.disconnect provider.radio 0x234
    wire.sent provider.radio 0x235 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x235 #[0x0b, 43]
    wire.disconnect provider.radio 0x235
  try:
    first := a.connect (links.address 1) --address-type=1
    second := b.connect (links.address 2) --address-type=1
    expect-equals #[41] (first.read 3)
    expect-equals #[42] (second.read 3)
    first.disconnect
    expect (not provider.radio.closed)
    expect-equals #[43] (second.read 3)
    second.disconnect
    expect provider.radio.closed
    expect-equals 1 provider.opens
  finally:
    a.close
    b.close
    provider.uninstall
    responder.cancel

pending won/bool:
  provider := Provider
  provider.install
  a := clients.Client
  b := clients.Client
  a.open
  b.open
  enabled := monitor.Latch
  release := monitor.Latch
  responder := task::
    initialize provider.radio
    owner/central.Central := provider.ready.get
    connect.establish provider.radio owner 1 0x234 --extended-mode
    accept.setup provider.radio
    accept.enabled provider.radio
    enabled.set true
    release.get
    if won: accept.connected provider.radio
    accept.terminal provider.radio --won=won
    accept.remove provider.radio
    if won: wire.disconnect provider.radio 0x235
    wire.sent provider.radio 0x234 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x234 #[0x0b, 42]
    wire.disconnect provider.radio 0x234
  try:
    survivor := a.connect (links.address 1) --address-type=1
    b.session
    enabled.get
    b.close
    yield
    expect (not provider.last-peripheral.is-released)
    expect (not provider.radio.closed)
    release.set true
    while not provider.last-peripheral.is-released: sleep --ms=1
    expect-equals #[42] (survivor.read 3)
    survivor.disconnect
    expect provider.radio.closed
    expect-equals 1 provider.opens
  finally:
    release.set true
    a.close
    b.close
    provider.uninstall
    responder.cancel

admission:
  modes := [api.CONNECT, api.OPEN, api.OPEN-BUILDER, api.OPEN-BOUNDED-BUILDER,
    api.OPEN-SCAN, api.OPEN-ADVERTISING]
  [false, true].do: | mixed/bool |
    modes.do: | first/int |
      modes.do: | second/int |
        provider := AdmissionProvider mixed
        a := provider.handle first (arguments first) --gid=1 --client=1
        b/rpc.Session? := null
        try:
          expect-throw "GATT_SERVICE_BUSY":
            provider.handle second (arguments second) --gid=1 --client=1
          allowed := (first == api.CONNECT and second == api.CONNECT) or
              (mixed and ((first == api.CONNECT and (peripheral-mode second)) or
                (second == api.CONNECT and (peripheral-mode first))))
          if allowed:
            b = provider.handle second (arguments second) --gid=1 --client=2
            // Two central sessions and one peripheral session fit, the
            // roles together only with mixed roles.
            centrals := (first == api.CONNECT ? 1 : 0) + (second == api.CONNECT ? 1 : 0)
            peripherals := 2 - centrals
            modes.do: | third/int |
              fits := third == api.CONNECT
                  ? centrals < 2 and (peripherals == 0 or mixed)
                  : (peripheral-mode third) and peripherals < 1 and (centrals == 0 or mixed)
              if fits:
                (provider.handle third (arguments third) --gid=1 --client=3).close
              else:
                expect-throw "GATT_SERVICE_BUSY":
                  provider.handle third (arguments third) --gid=1 --client=3
          else:
            expect-throw "GATT_SERVICE_BUSY":
              provider.handle second (arguments second) --gid=1 --client=2
        finally:
          a.close
          if b: b.close

peripheral-mode mode/int -> bool:
  return mode == api.OPEN or mode == api.OPEN-BUILDER or mode == api.OPEN-BOUNDED-BUILDER

arguments mode/int -> any:
  if mode == api.OPEN: return null
  if mode == api.OPEN-BUILDER: return "matrix"
  if mode == api.OPEN-BOUNDED-BUILDER: return ["matrix", 20, 23]
  return []

class AdmissionProvider extends rpc.Provider:
  mixed_/bool
  constructor .mixed_: super
  central-session-limit -> int: return 2
  mixed-role-sessions -> bool: return mixed_
  create-session client/int -> rpc.Session: return AdmissionSession this client 1
  create-builder client/int name/string -> rpc.Session: return create-session client
  create-connection client/int arguments/List -> rpc.Session: return AdmissionSession this client 2
  create-scan client/int arguments/List -> rpc.Session: return AdmissionSession this client 0
  create-advertising client/int arguments/List -> rpc.Session: return AdmissionSession this client 0

class AdmissionSession extends rpc.Session:
  role_/int
  constructor provider/rpc.Provider client/int .role_: super provider client
  is-central -> bool: return role_ == 2
  is-peripheral -> bool: return role_ == 1

initialize radio/fixture.FakeTransport --missing/int=-1:
  fixture.initialize-replies radio --extended
  fixture.reply radio #[1, 1, 0x20, 8, 0x5f, 0x0a, 0, 0, 0, 0, 0, 0] #[]
  fixture.reply radio #[1, 1, 0x20, 8, 0x5f, 0x0a, 2, 0, 0, 0, 0, 0] #[]
  fixture.reply radio #[1, 0x1c, 0x20, 0] #[0, 0, 0, 0, missing == 0 ? 0 : 8, missing == 1 ? 0 : 2, 0, 0]

peripheral radio/fixture.FakeTransport:
  accept.setup radio
  accept.enabled radio
  accept.connected radio
  accept.terminal radio --won
  accept.remove radio
  packet := radio.sent.take
  expect-equals #[2, 0x35, 2] packet[..3]
  expect-equals #[5, 0] packet[7..9]
  links.completed radio 0x235

read-peripheral radio/fixture.FakeTransport:
  wire.incoming radio 0x235 #[0x0a, 3, 0]
  wire.sent radio 0x235 (#[0x0b] + "Toit".to-byte-array)

held-disconnect radio/fixture.FakeTransport handle/int seen/monitor.Latch release/monitor.Latch:
  parameters := #[0, 0, 0x13]
  io.LITTLE-ENDIAN.put-uint16 parameters 0 handle
  expect-equals (hci.command-packet 0x0406 parameters) radio.sent.take
  seen.set true
  release.get
  radio.received.add #[4, 15, 4, 0, 1, 6, 4]
  links.ended radio handle

run peripheral-first/bool close-central/bool:
  provider := OneEachProvider
  provider.install
  central-client := clients.Client
  peripheral-client := clients.Client
  third := clients.Client
  central-client.open
  peripheral-client.open
  third.open
  first-read := monitor.Latch
  closing := monitor.Latch
  release := monitor.Latch
  survivor-read := monitor.Latch
  replacement-read := monitor.Latch
  responder := task::
    initialize provider.radio
    owner/central.Central := provider.ready.get
    if peripheral-first: peripheral provider.radio
    connect.establish provider.radio owner 1 0x234 --extended-mode
    if not peripheral-first: peripheral provider.radio
    wire.sent provider.radio 0x234 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x234 #[0x0b, 42]
    read-peripheral provider.radio
    first-read.set true
    held-disconnect provider.radio (close-central ? 0x234 : 0x235) closing release
    if close-central:
      read-peripheral provider.radio
      survivor-read.set true
      connect.establish provider.radio owner 3 0x234 --extended-mode
      wire.sent provider.radio 0x234 #[0x0a, 3, 0]
      wire.incoming provider.radio 0x234 #[0x0b, 43]
      wire.disconnect provider.radio 0x234
      wire.disconnect provider.radio 0x235
    else:
      wire.sent provider.radio 0x234 #[0x0a, 3, 0]
      wire.incoming provider.radio 0x234 #[0x0b, 43]
      peripheral provider.radio
      read-peripheral provider.radio
      replacement-read.set true
      wire.disconnect provider.radio 0x235
      wire.disconnect provider.radio 0x234
  try:
    capabilities := third.capabilities
    expect capabilities.mixed-roles
    expect-equals 2 capabilities.max-sessions
    expect-equals 0 provider.opens
    p/clients.Session? := null
    if peripheral-first:
      p = peripheral-client.session
      p.peer
    c := central-client.connect (links.address 1) --address-type=1
    if not p:
      p = peripheral-client.session
      p.peer
    expect-equals 1 provider.opens
    expect-throw "GATT_SERVICE_BUSY": central-client.configure
    expect-throw "GATT_SERVICE_BUSY": third.configure
    expect-throw "GATT_SERVICE_BUSY": third.connect (links.address 3) --address-type=1
    retained := c.read 3
    expect-equals #[42] retained
    first-read.get
    system.process-stats --gc
    expect-equals #[42] retained
    old := close-central ? provider.last-central : provider.last-peripheral
    if close-central: central-client.close
    else: peripheral-client.close
    closing.get
    expect (not old.is-released)
    expect (not provider.radio.closed)
    expect-throw "GATT_SERVICE_BUSY": third.connect (links.address 3) --address-type=1
    release.set true
    while not old.is-released: sleep --ms=1
    if close-central:
      survivor-read.get
      replacement := third.connect (links.address 3) --address-type=1
      expect-equals #[43] (replacement.read 3)
      replacement.disconnect
      p.close
      while not provider.last-peripheral.is-released: sleep --ms=1
    else:
      expect-equals #[43] (c.read 3)
      replacement := third.session
      replacement.peer
      replacement-read.get
      replacement.close
      while not provider.last-peripheral.is-released: sleep --ms=1
      c.disconnect
    expect provider.radio.closed
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
  finally:
    release.set true
    central-client.close
    peripheral-client.close
    third.close
    provider.uninstall
    responder.cancel

unsupported missing/int:
  provider := Provider
  provider.install
  client := clients.Client
  client.open
  responder := task:: initialize provider.radio --missing=missing
  try:
    expect client.capabilities.mixed-roles
    expect-throw "GATT_MIXED_CONTROLLER_UNSUPPORTED":
      client.connect (links.address 1) --address-type=1
    while not provider.last-central.is-released: sleep --ms=1
    expect provider.radio.closed
    expect-equals 1 provider.opens
  finally:
    client.close
    provider.uninstall
    responder.cancel

class Radio extends fixture.FakeTransport:
  closes/int := 0
  close -> none:
    closes++
    super

class Provider extends mixed.Provider:
  radio/Radio ::= Radio
  ready/monitor.Latch ::= monitor.Latch
  opens/int := 0
  last-central/rpc.Session? := null
  last-peripheral/rpc.Session? := null

  mixed-role-sessions -> bool: return true

  open-transport -> Radio:
    opens++
    return radio

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    owner := super controller info receive-limit
    ready.set owner
    return owner

  create-connection client/int arguments/List -> rpc.Session:
    last-central = super client arguments
    return last-central

  create-session client/int -> rpc.Session:
    last-peripheral = super client
    return last-peripheral

// One central and one peripheral session: the controller is then full.
class OneEachProvider extends Provider:
  central-session-limit -> int: return 1
