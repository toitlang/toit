// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api as api
import ble.experimental.service.gatt-provider as gatt
import ble.experimental.service.mixed-provider as mixed
import ble.experimental.service.provider as rpc
import ble.experimental.transport
import monitor
import system
import .mixed-service-provider as containers-fixture
import .mixed-update-provider as radio-fixture
import .mixed-update-exit-app as exit-app
import .mixed-update-lost-app as app

main: run 0

run boundary/int:
  with-timeout --ms=85_000:
    provider := Provider boundary
    provider.install
    children := []
    groups := {}
    watcher/Task? := null
    before := system.process-stats
    collector := task --background::
      while true:
        sleep --ms=500
        system.process-stats --gc
    try:
      central := containers-fixture.start "mixed-lost-a" [0]
      children.add central
      groups.add central.gid
      watcher = task --background::
        code := central.wait
        if code != 0:
          provider.events.do: if not it.has-value: it.set "MIXED_LOST_CENTRAL_FAILED" --exception
      provider.events[0].get
      doomed := containers-fixture.start "mixed-lost-a" [1, boundary]
      children.add doomed
      groups.add doomed.gid
      if doomed.wait != 0: throw "MIXED_LOST_CLIENT_FAILED"
      if central.wait != 0: throw "MIXED_LOST_CENTRAL_FAILED"
      with-timeout --ms=5_000:
        while not provider.last.is-released or not provider.central-session.is-released:
          sleep --ms=1
      radio := provider.radio
      elapsed := radio.closed-us - radio.dropped-us
      if provider.opens != 1 or radio.closes != 1 or not radio.dropped or
          not provider.last.closed-with-update or provider.last.updating or
          radio.commands-after-drop != 0 or not 0 < elapsed <= 5_000_000:
        throw "MIXED_LOST_CLEANUP"
      if radio.reads != [100, 100, 1, 0, 0, 0] or radio.parameters != 1 or
          radio.data-count != 2 or radio.response-count != boundary + 1 or
          radio.removes != 0 or radio.disables != 0 or not radio.command-errors.is-empty:
        throw "MIXED_LOST_COMMAND_COUNTS"
      print "MIXED_LOST CLOSED boundary=$boundary opens=1 closes=1 pending-at-death=true reads=200 pending-reads=1 data=2 response=$(boundary + 1) removes=0 commands-after-drop=0 elapsed-us=$elapsed"
      provider.recovering = true
      sleep --ms=3_000
      recovery := containers-fixture.start "mixed-lost-a" [2]
      children.add recovery
      groups.add recovery.gid
      if recovery.wait != 0: throw "MIXED_LOST_RECOVERY_FAILED"
      with-timeout --ms=5_000:
        while not provider.last.is-released: sleep --ms=1
      provider.uninstall --wait
      recovered := provider.radio
      if provider.opens != 2 or identical radio recovered or recovered.closes != 1 or
          recovered.dropped or recovered.data-count != 1 or recovered.response-count != 1 or
          recovered.parameters != 1 or recovered.removes != 1 or recovered.disables != 0 or
          recovered.enables != recovered.terminated or recovered.last-status != 0 or
          not recovered.command-errors.is-empty or groups.size != 3:
        throw "MIXED_LOST_RECOVERY_LIFETIME"
      gcs := exit-app.gc-count before
      if gcs < 5: throw "MIXED_LOST_PROVIDER_GC_MISSING"
      print "MIXED_LOST_PROVIDER COMPLETE boundary=$boundary opens=2 closes=2 recovery-data=1 recovery-response=1 recovery-removes=1 recovery-enables=$(recovered.enables) recovery-terminations=$(recovered.terminated) full-gcs=$gcs"
      print "MIXED_LOST_SUPERVISOR COMPLETE child-groups=3 exits=0"
    finally: | failing _ |
      critical-do --no-respect-deadline:
        if watcher: watcher.cancel
        collector.cancel
        error := catch:
          children.do: it.close
          provider.uninstall
        if error and not failing: throw error

class Provider extends mixed.Provider:
  boundary/int
  recovering/bool := false
  opens/int := 0
  radio/Radio? := null
  last/Session? := null
  central-session/rpc.Session? := null
  events/List ::= List 7: monitor.Latch
  constructor .boundary: super
  receive-acl-packets -> int: return 4
  open-transport -> transport.Transport:
    opens++
    radio = Radio (recovering ? 0 : 0x2037 + boundary)
    return radio
  create-builder client/int name/string -> rpc.Session:
    last = Session this client name
    return last
  create-connection client/int arguments/List -> rpc.Session:
    central-session = super client arguments
    return central-session
  handle index/int arguments/any --gid/int --client/int -> any:
    if recovering and index == exit-app.ENABLED:
      radio.first-enabled.get
      return null
    if index == app.BASELINE or index == app.ADVERTISING-READS-DONE:
      phase := index == app.BASELINE ? 0 : 1
      if radio.reads[phase] != 100: throw "MIXED_LOST_BATCH_COUNT"
      events[index - 1000].set true
      return null
    if index == app.READ-WHILE-ADVERTISING or index == app.FAIL-READ:
      return events[index - 1000].get
    if index == app.ENABLED:
      radio.first-enabled.get
      radio.phase = 1
      events[1].set true
      events[2].get
      return null
    if index == app.FRESH-WINDOW:
      radio.fresh = monitor.Latch
      radio.fresh.get
      return null
    if index == app.DROPPED:
      radio.drop.get
      if not last.updating: throw "MIXED_LOST_NOT_PENDING"
      radio.phase = 2
      events[6].set true
      return null
    return super index arguments --gid=gid --client=client

class Session extends gatt.Session:
  updating/bool := false
  closed-with-update/bool := false
  constructor owner/Provider client/int name/string:
    super owner client --name=name
  invoke index/int arguments/List -> any:
    if index != api.PERIPHERAL-ADVERTISING-UPDATE: return super index arguments
    updating = true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline: updating = false
  on-closed -> none:
    closed-with-update = updating
    super

class Radio extends radio-fixture.Radio:
  opcode/int
  replies/int := 0
  dropped/bool := false
  dropped-us/int := 0
  closed-us/int := 0
  commands-after-drop/int := 0
  drop/monitor.Latch ::= monitor.Latch
  fresh/monitor.Latch? := null
  constructor .opcode: super
  record packet/ByteArray:
    super packet
    // Host Number Of Completed Packets is independent receive-credit accounting.
    if dropped and packet.size >= 4 and packet[0] == 1 and packet[1..3] != #[0x35, 0x0c]:
      commands-after-drop++
  receive -> ByteArray:
    while true:
      packet := super
      if packet.size == 7 and packet[0..3] == #[4, 14, 4]:
        command := packet[4] | packet[5] << 8
        if command == 0x2039 and packet[6] == 0 and fresh: fresh.set true
        if command == opcode:
          replies++
          if replies == 2:
            if packet[6] != 0: throw "MIXED_LOST_UPDATE_REJECTED"
            dropped = true
            dropped-us = Time.monotonic-us
            print "MIXED_LOST DROPPED opcode=$opcode status=0"
            drop.set true
            // Lose this reply, then keep delivering events and ACL packets.
            // The production command deadline must fail the controller.
            continue
      return packet
  close -> none:
    if closes != 0: return
    super
    closed-us = Time.monotonic-us
