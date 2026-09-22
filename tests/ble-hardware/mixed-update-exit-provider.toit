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
import system.containers
import .mixed-service-provider as containers-fixture
import .mixed-update-provider as radio-fixture
import .mixed-update-exit-app as app

main:
  with-timeout --ms=160_000:
    provider := Provider
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
      central := containers-fixture.start "mixed-exit-a" [0]
      children.add central
      groups.add central.gid
      watcher = task --background::
        code := central.wait
        if code != 0:
          critical-do --no-respect-deadline:
            provider.done.do: if not it.has-value: it.set "MIXED_EXIT_CENTRAL_FAILED" --exception
            provider.ready.do: if not it.has-value: it.set "MIXED_EXIT_CENTRAL_FAILED" --exception
      provider.done[0].get
      3.repeat: | stage/int |
        provider.stage = stage
        provider.radio.stage = stage
        peripheral := containers-fixture.start "mixed-exit-a" [1, stage]
        children.add peripheral
        if groups.contains peripheral.gid: throw "CONTAINER_GROUP_REUSED"
        groups.add peripheral.gid
        if peripheral.wait != 0: throw "MIXED_EXIT_CLIENT_FAILED"
        while not provider.last.is-released: sleep --ms=1
        provider.check-cleanup
        batch := stage < 2 ? stage * 2 + 2 : 5
        provider.start-batch batch
        provider.done[batch].get
        if stage < 2: sleep --ms=3_000
      if central.wait != 0: throw "MIXED_EXIT_CENTRAL_FAILED"
      provider.uninstall --wait
      radio := provider.radio
      if provider.opens != 1 or radio.closes != 1 or radio.reads != [100, 100, 100, 100, 100, 100]:
        throw "MIXED_EXIT_CONTROLLER_LIFETIME"
      if radio.parameters != 3 or radio.removes != 3 or radio.data-count != 5 or
          radio.response-count != 4 or radio.disables != 0 or radio.enables != radio.terminated or
          radio.terminated < 5 or radio.last-status != 0 or not radio.command-errors.is-empty:
        throw "MIXED_EXIT_CONTROLLER_COUNTS"
      gcs := app.gc-count before
      if gcs < 20: throw "MIXED_EXIT_PROVIDER_GC_MISSING"
      print "MIXED_EXIT_PROVIDER COMPLETE opens=1 closes=1 data=5 response=4 parameters=3 removes=3 disables=0 enables=$(radio.enables) terminations=$(radio.terminated) phase-reads=100,100,100,100,100,100 full-gcs=$gcs"
      print "MIXED_EXIT_SUPERVISOR COMPLETE child-groups=4 exits=0"
    finally: | failing _ |
      critical-do --no-respect-deadline:
        if watcher: watcher.cancel
        collector.cancel
        if provider.radio:
          provider.radio.release.do: it.set true
        cleanup-error := catch:
          children.do: it.close
          provider.uninstall
        if cleanup-error and not failing: throw cleanup-error

class Provider extends mixed.Provider:
  stage/int := 0
  opens/int := 0
  radio/Radio? := null
  last/Session? := null
  ready/List ::= List 6: monitor.Latch
  done/List ::= List 6: monitor.Latch
  constructor: super
  receive-acl-packets -> int: return 4
  open-transport -> transport.Transport:
    opens++
    radio = Radio
    return radio
  create-builder client/int name/string -> rpc.Session:
    last = Session this client name stage
    return last
  start-batch batch/int:
    if radio.closes != 0: throw "MIXED_EXIT_SURVIVOR_CLOSED"
    radio.phase = batch
    ready[batch].set true
  check-cleanup:
    pending := stage < 2
    if last.updating or last.closed-with-update != pending or radio.closes != 0:
      throw "MIXED_EXIT_PENDING_OR_SURVIVOR"
    data := stage < 2 ? (stage + 1) * 2 : 5
    response := stage < 2 ? stage * 2 + 1 : 4
    if radio.data-count != data or radio.response-count != response or radio.removes != stage + 1:
      throw "MIXED_EXIT_CLEANUP_COUNTS"
    print "MIXED_EXIT CLEANUP stage=$stage pending-at-death=$pending closes=0 data=$data response=$response removes=$(stage + 1)"
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == app.WAIT-BATCH: return ready[arguments].get
    if index == app.DONE:
      batch/int := arguments
      if radio.reads[batch] != 100: throw "MIXED_EXIT_BATCH_COUNT"
      done[batch].set true
      return null
    if index == app.ENABLED:
      radio.enabled[stage].get
      if stage < 2:
        batch := stage * 2 + 1
        start-batch batch
        done[batch].get
      return null
    if index == app.FRESH-WINDOW:
      radio.fresh = monitor.Latch
      radio.fresh.get
      return null
    if index == app.HELD:
      radio.held[stage].get
      if not last.updating: throw "MIXED_EXIT_NOT_PENDING"
      return null
    return super index arguments --gid=gid --client=client

class Session extends gatt.Session:
  owner_/Provider
  stage_/int
  updating/bool := false
  closed-with-update/bool := false
  constructor .owner_ client/int name/string .stage_:
    super owner_ client --name=name
  invoke index/int arguments/List -> any:
    if index != api.PERIPHERAL-ADVERTISING-UPDATE: return super index arguments
    updating = true
    try:
      return super index arguments
    finally:
      critical-do --no-respect-deadline: updating = false
  on-closed -> none:
    closed-with-update = updating
    try:
      super
    finally:
      if stage_ < 2: owner_.radio.release[stage_].set true

class Radio extends radio-fixture.Radio:
  stage/int := 0
  enabled/List ::= [monitor.Latch, monitor.Latch, monitor.Latch]
  held/List ::= [monitor.Latch, monitor.Latch]
  release/List ::= [monitor.Latch, monitor.Latch]
  fresh/monitor.Latch? := null
  replies_/List ::= [0, 0]
  constructor: super
  receive -> ByteArray:
    packet := super
    if packet.size >= 8 and packet[0..2] == #[4, 0x3e] and (packet[3] == 1 or packet[3] == 10):
      print "MIXED_EXIT CONNECTION status=$(packet[4]) role=$(packet[7]) handle=$(packet[5] | packet[6] << 8)"
    if packet.size == 7 and packet[0..2] == #[4, 5]:
      print "MIXED_EXIT DISCONNECTION status=$(packet[3]) handle=$(packet[4] | packet[5] << 8) reason=$(packet[6])"
    if packet.size == 7 and packet[0..3] == #[4, 14, 4] and packet[5] == 32:
      if packet[4] == 0x39 and packet[6] == 0:
        enabled[stage].set true
        if fresh: fresh.set true
      if stage < 2 and packet[4] == 0x37 + stage:
        replies_[stage]++
        if replies_[stage] == 2:
          if packet[6] != 0: throw "MIXED_EXIT_UPDATE_REJECTED"
          print "MIXED_EXIT HELD stage=$stage opcode=$(0x2037 + stage) status=0"
          held[stage].set true
          release[stage].get
    return packet
