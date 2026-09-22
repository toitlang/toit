// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import ble.experimental.advertising-updates as updates
import ble.experimental.central as central
import ble.experimental.bounded-central as bounded
import ble.experimental.hci as hci
import .ble-accept-update-test as update-fixture
import .ble-bounded-accept-test as bounded-fixture
import .ble-connect-isolation-test as connections
import .ble-hci-test as fixture
import .ble-peripheral-test as legacy
import .ble-multilink-test as links

main:
  with-timeout --ms=30_000:
    [false, true].do: | extended/bool |
      [false, true].do: | second/bool |
        ["update-cancel", "accept-cancel", "lost"].do: run it extended second

run mode/string extended/bool second/bool:
  radio := Radio
  host/central.Central := extended
      ? (bounded.Central (hci.Controller radio) --link-limit=2 --acl-count=2)
      : (central.Central (hci.Controller radio))
  changes := updates.Changes
  held := monitor.Latch
  release := monitor.Latch
  update-ended := monitor.Latch
  accept-ended := monitor.Latch
  responder-ended := monitor.Latch
  first-opcode := extended ? 0x2037 : 0x2008
  opcode := first-opcode + (second ? 1 : 0)
  request := hci.command-packet opcode (update-fixture.encode #[42] extended)
  responder := task::
    try:
      if extended:
        connections.establish radio host 1 0x234 --extended-mode
        bounded-fixture.setup radio
        bounded-fixture.enabled radio
      else:
        legacy.setup radio
      if second: legacy.reply radio first-opcode (update-fixture.encode #[42] extended)
      expect-equals request radio.sent.take
      held.set true
      release.get
      if mode == "lost":
        while not radio.closed: sleep --ms=1
      else:
        update-fixture.reply radio opcode
        if extended:
          bounded-fixture.terminal radio
          bounded-fixture.remove radio
          links.incoming radio 0x234 #[1, 0, 4, 0, 0xa1] --start
          expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xa2] radio.sent.take
          links.completed radio 0x234
    finally:
      critical-do --no-respect-deadline: responder-ended.set true
  survivor := extended ? (host.connect (links.address 1) --address-type=1) : null
  accepter := task::
    result := null
    error := null
    try:
      error = catch: result = host.accept #[2, 1, 6] --updates=changes
    finally:
      critical-do --no-respect-deadline: accept-ended.set [result, error]
  updater := task::
    result := null
    error := null
    try:
      error = catch: result = changes.update #[42] #[42]
    finally:
      critical-do --no-respect-deadline: update-ended.set [result, error]
  try:
    held.get
    if mode == "update-cancel":
      updater.cancel
      update-ended.get
    if mode == "accept-cancel": accepter.cancel
    release.set true
    update-result := update-ended.get
    accept-result := accept-ended.get
    expect-null accept-result[0]
    if mode == "lost":
      expect (["DEADLINE_EXCEEDED", "HCI_COMMAND_ABORTED"].contains update-result[1])
      expect (["DEADLINE_EXCEEDED", "HCI_COMMAND_ABORTED"].contains accept-result[1])
      expect radio.closed
      expect-equals request radio.history.last
      if survivor: expect (not (host.owns-link survivor))
    else:
      if mode == "accept-cancel": expect-equals [false, null] update-result
      else: expect-null update-result[0]
      if extended:
        expect (host.owns-link survivor)
        expect-equals #[0xa1] survivor.receive.payload
        host.send survivor 4 #[0xa2]
      else:
        expect radio.closed
        expect-equals request radio.history.last
    responder-ended.get
  finally:
    host.close
    host.wait-closed
    accepter.cancel
    updater.cancel
    responder.cancel

class Radio extends fixture.FakeTransport:
  history/List := []
  constructor: super

  send packet/ByteArray -> none:
    super packet
    history.add packet.copy
