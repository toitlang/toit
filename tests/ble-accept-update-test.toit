// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import ble.experimental.advertising-updates as updates
import ble.experimental.bounded-central as bounded
import ble.experimental.central as central
import ble.experimental.hci as hci
import .ble-bounded-accept-test as bounded-fixture
import .ble-fixture as fixture
import .ble-peripheral-test as legacy
import .ble-connect-isolation-test as connections
import .ble-multilink-test as links

main:
  with-timeout --ms=30_000:
    [false, true].do: | extended/bool |
      ["normal", "window", "win-first", "win-second", "cancel", "first-error", "second-error"].do:
        run it extended

run mode/string extended/bool:
  radio := fixture.FakeTransport
  host/central.Central := extended
      ? (bounded.Central (hci.Controller radio) --link-limit=2 --acl-count=2)
      : (central.Central (hci.Controller radio))
  changes := updates.Changes
  started := monitor.Latch
  release := monitor.Latch
  updated := monitor.Latch
  accepted := monitor.Latch
  finish := monitor.Latch
  responder-ended := monitor.Latch
  data := ByteArray 31: it
  response := ByteArray 31: 31 - it
  expected-data := data.copy
  expected-response := response.copy
  first := extended ? 0x2037 : 0x2008
  second := extended ? 0x2038 : 0x2009
  won := mode == "win-first" or mode == "win-second"
  failed := mode == "first-error" or mode == "second-error" or mode == "cancel"
  updater/Task? := null
  responder := task::
    try:
      if extended:
        connections.establish radio host 1 0x234 --extended-mode
        bounded-fixture.setup radio
        bounded-fixture.enabled radio
      else:
        legacy.setup radio
      expect-equals (hci.command-packet first (encode expected-data extended)) radio.sent.take
      started.set true
      release.get
      if extended and mode == "window": bounded-fixture.terminal radio
      if mode == "win-first":
        connected radio extended
        while not changes.ended: sleep --ms=1
      reply radio first --fail=(mode == "first-error")
      if mode != "win-first" and mode != "cancel" and mode != "first-error":
        expect-equals (hci.command-packet second (encode expected-response extended)) radio.sent.take
        if mode == "win-second":
          connected radio extended
          while not changes.ended: sleep --ms=1
        reply radio second --fail=(mode == "second-error")
      if not failed and not won:
        if extended and mode == "window": bounded-fixture.enabled radio
        legacy.reply radio first (encode #[] extended)
        legacy.reply radio second (encode #[] extended)
        // No disable/re-enable is allowed between the successful update and connection.
        finish.get
        connected radio extended
      if extended:
        bounded-fixture.terminal radio --won=(not failed)
        bounded-fixture.remove radio
      else if not failed:
        legacy.reply radio 0x200a #[0]
      if not failed:
        if extended:
          bounded-fixture.disconnect radio
        else:
          fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
          radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
      if extended:
        links.incoming radio 0x234 #[1, 0, 4, 0, 0xa1] --start
        expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xa2] radio.sent.take
        links.completed radio 0x234
    finally:
      critical-do --no-respect-deadline: responder-ended.set true
  survivor := extended ? (host.connect (links.address 1) --address-type=1) : null
  accepter := task::
    result := null
    error := catch: result = host.accept #[2, 1, 6] --updates=changes
    accepted.set [result, error]
  try:
    expect-throw "INVALID_ARGUMENT": changes.update (ByteArray 32) #[]
    updater = task::
      result := null
      error := null
      try:
        error = catch: result = changes.update data response
      finally:
        critical-do --no-respect-deadline: updated.set [result, error]
    started.get
    data.fill 99
    response.fill 98
    system.process-stats --gc
    expect-throw "BLE_ADVERTISING_UPDATE_BUSY": changes.update #[] #[]
    if mode == "cancel":
      updater.cancel
      updated.get
    release.set true
    result := updated.get
    if mode == "first-error" or mode == "second-error":
      expect (result[1] is string and result[1].contains "status=12")
    else if mode == "cancel":
      expect-null result[0]
    else:
      expect-null result[1]
      expect-equals (not won) result[0]
      if not won: expect (changes.update #[] #[])
    finish.set true
    outcome := accepted.get
    if failed:
      expect-not-null outcome[1]
      if not extended: expect radio.closed
    else:
      expect-null outcome[1]
      expect (not (changes.update #[] #[]))
      link/central.Link := outcome[0]
      expect link.connected
      host.disconnect link
      link.wait-disconnected
    if extended:
      expect (host.owns-link survivor)
      expect-equals #[0xa1] survivor.receive.payload
      host.send survivor 4 #[0xa2]
    responder-ended.get
  finally:
    host.close
    host.wait-closed
    accepter.cancel
    if updater: updater.cancel
    responder.cancel

encode bytes/ByteArray extended/bool -> ByteArray:
  return extended ? (#[0, 3, 1, bytes.size] + bytes) : (#[bytes.size] + bytes + (ByteArray (31 - bytes.size)))

reply radio/fixture.FakeTransport opcode/int --fail/bool=false:
  radio.received.add #[4, 14, 4, 1, opcode & 0xff, opcode >> 8, fail ? 12 : 0]

connected radio/fixture.FakeTransport extended/bool:
  if extended:
    bounded-fixture.connected radio
  else:
    event := fixture.connection-event.copy
    event[7] = 1
    radio.received.add event
