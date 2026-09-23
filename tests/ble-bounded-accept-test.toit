// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bounded-central as bounded
import ble.experimental.central
import ble.experimental.hci
import expect show *
import io
import monitor
import system
import .ble-connect-isolation-test as connections
import .ble-fixture as fixture
import .ble-multilink-test as links

main:
  with-timeout --ms=35_000:
    configuration
    ["expired", "won", "after-connection", "deadline", "missing", "wrong-set",
      "wrong-handle", "rejected", "remove-failed", "disconnect-failed",
      "early-expiry", "early-win", "restart"].do: run it
    run "restart" --private
    4.repeat: | stage/int |
      ["cancel", "deadline", "rejected"].do: setup-interrupted stage it
    setup-interrupted 0 "malformed"
    ["malformed", "close", "transport", "won-malformed", "won-close",
      "won-transport", "hook"].do: failure-wakes-window it

setup radio/fixture.FakeTransport --private/bool=false:
  fixture.reply radio (hci.command-packet 0x2036 #[
    0, 0x13, 0, 160, 0, 0, 160, 0, 0, 7, private ? 1 : 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x7f, 1, 0, 1, 0, 0,
  ]) #[0]
  if private:
    fixture.reply radio #[1, 0x35, 0x20, 7, 0, 1, 2, 3, 4, 5, 0xc6] #[]
  fixture.reply radio #[1, 0x37, 0x20, 7, 0, 3, 1, 3, 2, 1, 6] #[]
  fixture.reply radio #[1, 0x38, 0x20, 4, 0, 3, 1, 0] #[]

enabled radio/fixture.FakeTransport:
  fixture.reply radio #[1, 0x39, 0x20, 6, 1, 1, 0, 100, 0, 0] #[]

terminal radio/fixture.FakeTransport --won/bool=false --set/int=0 --handle/int=0x235:
  packet := #[4, 0x3e, 6, 0x12, won ? 0 : 0x3c, set, 0, 0, 0]
  io.LITTLE-ENDIAN.put-uint16 packet 6 handle
  radio.received.add packet

connected radio/fixture.FakeTransport:
  event := connections.completed-connection 2 0x235
  event[7] = 1
  radio.received.add event

remove radio/fixture.FakeTransport --fail/bool=false:
  expect-equals #[1, 0x3c, 0x20, 1, 0] radio.sent.take
  radio.received.add #[4, 14, 4, 1, 0x3c, 0x20, fail ? 0x0c : 0]

disconnect radio/fixture.FakeTransport --fail/bool=false:
  expect-equals #[1, 6, 4, 3, 0x35, 2, 0x13] radio.sent.take
  radio.received.add #[4, 15, 4, fail ? 0x0c : 0, 1, 6, 4]
  if not fail: links.ended radio 0x235

run mode/string --private/bool=false:
  radio := fixture.FakeTransport
  host := bounded.Central (hci.Controller radio) --link-limit=2 --acl-count=2
  seen := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  done := monitor.Latch
  caller/Task? := null
  accepted-link/central.Link? := null
  returned := false
  failure := null
  fatal := ["missing", "wrong-set", "wrong-handle", "remove-failed", "disconnect-failed"].contains mode
  won := ["won", "after-connection", "wrong-handle", "disconnect-failed", "early-win", "restart"].contains mode
  early := mode == "early-expiry" or mode == "early-win"
  responder := task::
    connections.establish radio host 1 0x234 --extended-mode
    setup radio --private=private
    if early or mode == "rejected":
      expect-equals #[1, 0x39, 0x20, 6, 1, 1, 0, 100, 0, 0] radio.sent.take
      if early:
        if won: connected radio
        terminal radio --won=won
    else:
      enabled radio
    if mode == "after-connection":
      connected radio
      // An exact survivor packet is delivered only after the connection event
      // has been consumed by the shared reader; no timed scheduling guess.
      links.incoming radio 0x234 #[1, 0, 4, 0, 0xaa] --start
    if mode == "restart":
      // S3's extra timeout completion must not end the accept or steal a slot.
      // More than 32 windows also detect leaking these into the host event queue.
      40.repeat:
        timeout := connections.completed-connection 2 0x235
        timeout[4] = 0x3c
        radio.received.add timeout
        terminal radio
        system.process-stats --gc
        enabled radio
    seen.set true
    release.get
    if early or mode == "rejected":
      radio.received.add #[4, 14, 4, 1, 0x39, 0x20, mode == "rejected" ? 0x0c : 0]
    if not early and mode != "rejected" and mode != "missing":
      if won and mode != "after-connection": connected radio
      terminal radio --won=won --set=(mode == "wrong-set" ? 1 : 0)
          --handle=(mode == "wrong-handle" ? 0x236 : 0x235)
    if not ["missing", "wrong-set", "wrong-handle"].contains mode:
      remove radio --fail=(mode == "remove-failed")
      if won and mode != "restart": disconnect radio --fail=(mode == "disconnect-failed")
    ended.get
    if not fatal:
      links.incoming radio 0x234 #[1, 0, 4, 0, 0xa1] --start
      expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xa2] radio.sent.take
      links.completed radio 0x234
      if mode == "restart": disconnect radio
      setup radio
      enabled radio
      connected radio
      terminal radio --won
      remove radio
      links.incoming radio 0x235 #[1, 0, 4, 0, 0xb1] --start
    done.set true
  try:
    survivor := host.connect (links.address 1) --address-type=1
    caller = task::
      try:
        failure = catch:
          accepted-link = host.accept #[2, 1, 6] --timeout=(Duration --ms=(mode == "deadline" ? 30 : 10_000))
              --local-random-address=(private ? #[1, 2, 3, 4, 5, 0xc6] : null)
          returned = true
      finally:
        critical-do --no-respect-deadline: ended.set true
    seen.get
    if mode == "after-connection": expect-equals #[0xaa] survivor.receive.payload
    if mode == "deadline": sleep --ms=50
    else if mode != "restart": caller.cancel
    yield
    if mode != "restart": expect (not ended.has-value)
    release.set true
    with-timeout --ms=4_000: ended.get
    expect-equals (mode == "restart") returned
    if mode == "deadline": expect-equals DEADLINE-EXCEEDED-ERROR failure
    if fatal:
      expect (radio.closed and not survivor.connected)
    else:
      expect (survivor.connected and not radio.closed)
      expect-equals #[0xa1] survivor.receive.payload
      host.send survivor 4 #[0xa2]
      // A successful accepted link needs explicit release before replacement.
      if mode == "restart":
        expect-equals (private ? #[1, 2, 3, 4, 5, 0xc6] : null) accepted-link.local-random-address
        host.disconnect accepted-link
      replacement := host.accept #[2, 1, 6]
      expect-equals #[0xb1] replacement.receive.payload
      expect (replacement.connected and survivor.connected)
    done.get
  finally:
    if caller: caller.cancel
    responder.cancel
    host.close
    host.wait-closed

configuration:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  host/bounded.Central? := null
  responder := task::
    fixture.initialize-replies radio
    fixture.reply radio #[1, 1, 0x20, 8, 0x5f, 2, 0, 0, 0, 0, 0, 0] #[]
    fixture.reply radio #[1, 1, 0x20, 8, 0x5f, 2, 2, 0, 0, 0, 0, 0] #[]
  try:
    info := hci.initialize controller
    info.le-features[1] = 0x10
    info.commands[36] = 0x3e
    info.commands[37] = 0x81
    [1, 2, 3, 4, 5].do: | bit/int |
      info.commands[36] = 0x3e & ~(1 << bit)
      expect-throw "HCI_BOUNDED_ADVERTISING_UNSUPPORTED": bounded.configure controller info
    info.commands[36] = 0x3e
    [0, 7].do: | bit/int |
      info.commands[37] = 0x81 & ~(1 << bit)
      expect-throw "HCI_BOUNDED_ADVERTISING_UNSUPPORTED": bounded.configure controller info
    info.commands[37] = 0x81
    bounded.configure controller info
    host = bounded.Central controller
    expect-throw "INVALID_ARGUMENT": host.accept (ByteArray 32)
    expect-throw "INVALID_ARGUMENT": host.accept #[] --scan-response=(ByteArray 32)
    expect-throw "INVALID_ARGUMENT": host.accept #[] --interval=31
    expect-throw "INVALID_ARGUMENT": host.accept #[] --interval=0x4001
  finally:
    responder.cancel
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

// A terminal owner failure must wake the finite-window waiter, not consume
// another controller-event timeout in both the body and its cleanup.
failure-wakes-window mode/string --event/ByteArray?=null --error/string?=null:
  radio := fixture.FakeTransport
  host := FailureObserver (hci.Controller radio) --throw-from-hook=(mode == "hook")
  enabled := monitor.Latch
  ended := monitor.Latch
  failure := null
  caller/Task? := null
  responder := task::
    connections.establish radio host 1 0x234 --extended-mode
    setup radio
    fixture.reply radio #[1, 0x39, 0x20, 6, 1, 1, 0, 100, 0, 0] #[]
    enabled.set true
  try:
    survivor := host.connect (links.address 1) --address-type=1
    caller = task::
      try:
        failure = catch: host.accept #[2, 1, 6]
      finally:
        critical-do --no-respect-deadline: ended.set true
    enabled.get
    if mode.starts-with "won-":
      connected radio
      links.incoming radio 0x234 #[1, 0, 4, 0, 0xaa] --start
      expect-equals #[0xaa] survivor.receive.payload
    sent := radio.sent-count
    expected := error or "HCI_UNEXPECTED_ADVERTISING_TERMINATION"
    if mode == "close" or mode == "won-close":
      expected = "HCI_CLOSED"
      host.close
    else if mode == "transport" or mode == "won-transport":
      expected = "FAKE_CLOSED"
      radio.close
    else:
      if event: radio.received.add event
      else: terminal radio --set=1
    // First wait for proof that the reader has already rejected the event.
    expect-throw expected: survivor.receive
    with-timeout --ms=1_000: ended.get
    expect-equals expected failure
    host.wait-closed
    expect radio.closed
    expect-equals expected host.observed
    expect (host.calls > 0)
    host.close
    expect-equals expected host.observed
    expect-equals sent radio.sent-count
  finally:
    if caller: caller.cancel
    responder.cancel
    host.close
    host.wait-closed
    if caller:
      critical-do --no-respect-deadline: ended.get

class FailureObserver extends bounded.Central:
  observed := null
  calls/int := 0
  throw-from-hook_/bool

  constructor controller/hci.Controller --throw-from-hook/bool:
    throw-from-hook_ = throw-from-hook
    super controller --link-limit=2 --acl-count=2

  on-failure error -> none:
    calls++
    observed = error
    super error
    if throw-from-hook_: throw "TEST_FAILURE_HOOK"

setup-interrupted stage/int mode/string:
  radio := fixture.FakeTransport
  host := bounded.Central (hci.Controller radio) --link-limit=2 --acl-count=2
  seen := monitor.Latch
  release := monitor.Latch
  ended := monitor.Latch
  done := monitor.Latch
  caller/Task? := null
  failure := null
  commands := [
    (hci.command-packet 0x2036 #[0, 0x13, 0, 160, 0, 0, 160, 0, 0, 7, 1, 0,
                               0, 0, 0, 0, 0, 0, 0, 0x7f, 1, 0, 1, 0, 0]),
    #[1, 0x35, 0x20, 7, 0, 1, 2, 3, 4, 5, 0xc6],
    #[1, 0x37, 0x20, 7, 0, 3, 1, 3, 2, 1, 6],
    #[1, 0x38, 0x20, 4, 0, 3, 1, 0],
  ]
  responder := task::
    connections.establish radio host 1 0x234 --extended-mode
    (stage + 1).repeat: | index/int |
      command/ByteArray := commands[index]
      expect-equals command radio.sent.take
      if index == stage:
        seen.set true
        release.get
      rejected := index == stage and mode == "rejected"
      power := index == 0 and not rejected and mode != "malformed"
      response := #[4, 14, power ? 5 : 4, 1, command[1], command[2], rejected ? 0x0c : 0]
      if power: response += #[0]
      radio.received.add response
    if stage != 0 or mode != "rejected": remove radio
    ended.get
    links.incoming radio 0x234 #[1, 0, 4, 0, 0xc1] --start
    expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 0xc2] radio.sent.take
    links.completed radio 0x234
    setup radio
    enabled radio
    connected radio
    terminal radio --won
    remove radio
    links.incoming radio 0x235 #[1, 0, 4, 0, 0xc3] --start
    done.set true
  try:
    survivor := host.connect (links.address 1) --address-type=1
    caller = task::
      try:
        failure = catch:
          host.accept #[2, 1, 6] --local-random-address=#[1, 2, 3, 4, 5, 0xc6]
              --timeout=(Duration --ms=(mode == "deadline" ? 30 : 10_000))
          unreachable
      finally:
        critical-do --no-respect-deadline: ended.set true
    seen.get
    if mode == "cancel": caller.cancel
    if mode == "deadline": sleep --ms=50
    yield
    expect (not ended.has-value)
    release.set true
    ended.get
    if mode == "deadline": expect-equals DEADLINE-EXCEEDED-ERROR failure
    if mode == "rejected": expect (failure is hci.CommandError and failure.status == 0x0c)
    if mode == "malformed": expect-equals "HCI_MALFORMED_RESPONSE" failure
    expect (survivor.connected and not radio.closed)
    expect-equals #[0xc1] survivor.receive.payload
    host.send survivor 4 #[0xc2]
    replacement := host.accept #[2, 1, 6]
    expect-equals #[0xc3] replacement.receive.payload
    done.get
  finally:
    if caller: caller.cancel
    responder.cancel
    host.close
    host.wait-closed
