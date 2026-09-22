// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.service.mixed-provider as mixed
import ble.experimental.service.provider as rpc
import ble.experimental.transport
import monitor
import system
import system.containers
import .mixed-update-app as app
import .mixed-service-provider as containers-fixture
import .bounded-radio as radio-fixture

main:
  with-timeout --ms=95_000:
    provider := Provider
    provider.install
    central/containers.Container? := null
    peripheral/containers.Container? := null
    before := system.process-stats
    retained := ByteArray 64 --initial=42
    collector := task --background::
      while true:
        sleep --ms=500
        system.process-stats --gc
        retained.do: if it != 42: throw "MIXED_UPDATE_PROVIDER_RETAINED_CHANGED"
    try:
      central = containers-fixture.start "mixed-update-a" [0]
      peripheral = containers-fixture.start "mixed-update-a" [1]
      if central.gid == peripheral.gid: throw "CONTAINER_GROUP_REUSED"
      if peripheral.wait != 0 or central.wait != 0: throw "MIXED_UPDATE_CHILD_FAILED"
      provider.uninstall --wait
      radio := provider.radio
      if provider.opens != 1 or radio.closes != 1: throw "MIXED_UPDATE_CONTROLLER_LIFETIME"
      if radio.data-count != 4 or radio.response-count != 4 or radio.parameters != 1 or
          radio.removes != 1 or radio.disables != 0 or radio.enables != radio.terminated or
          radio.terminated < 3 or radio.last-status != 0 or not radio.command-errors.is-empty:
        throw "MIXED_UPDATE_CONTROLLER_COUNTS"
      if radio.reads != [100, 100, 100, 100, 100, 100]: throw "MIXED_UPDATE_PHASE_READS"
      if provider.groups != {central.gid, peripheral.gid}: throw "MIXED_UPDATE_CLIENT_GROUPS"
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if gcs < 20: throw "MIXED_UPDATE_PROVIDER_GC_MISSING"
      print "MIXED_UPDATE_PROVIDER COMPLETE opens=1 closes=1 data=4 response=4 parameters=1 removes=1 disables=0 enables=$(radio.enables) terminations=$(radio.terminated) phase-reads=100,100,100,100,100,100 full-gcs=$gcs"
      print "MIXED_UPDATE_SUPERVISOR COMPLETE child-groups=2 exits=0"
    finally:
      collector.cancel
      if peripheral: peripheral.close
      if central: central.close
      provider.uninstall

class Provider extends mixed.Provider:
  groups/Set ::= {}
  opens/int := 0
  radio/Radio? := null
  last/rpc.Session? := null
  baseline/monitor.Latch ::= monitor.Latch
  phases/List ::= [monitor.Latch, monitor.Latch, monitor.Latch, monitor.Latch]
  done/List ::= [monitor.Latch, monitor.Latch, monitor.Latch, monitor.Latch]
  ended/monitor.Latch ::= monitor.Latch
  constructor: super
  receive-acl-packets -> int: return 4
  open-transport -> transport.Transport:
    opens++
    radio = Radio
    return radio
  create-builder client/int name/string -> rpc.Session:
    last = super client name
    return last
  handle index/int arguments/any --gid/int --client/int -> any:
    if app.BASELINE <= index <= app.WAIT-ENDED:
      groups.add gid
      if index == app.BASELINE:
        if radio.reads[0] != 100: throw "MIXED_UPDATE_BASELINE"
        baseline.set true
      else if index == app.WAIT-BASELINE: baseline.get
      else if index == app.ENDED:
        done[3].get
        while not last.is-released: sleep --ms=1
        if radio.closes != 0: throw "MIXED_UPDATE_SURVIVOR_CLOSED"
        print "MIXED_UPDATE CLEANUP peripheral-released=true survivor-open=true"
        radio.phase = 5
        ended.set true
      else if index == app.WAIT-ENDED: ended.get
      else:
        phase/int := arguments
        if not 0 <= phase < 4: throw "INVALID_ARGUMENT"
        if index == app.PHASE:
          if phase == 0: radio.first-enabled.get
          if radio.reads[phase] != 100: throw "MIXED_UPDATE_PRIOR_BATCH"
          radio.phase = phase + 1
          phases[phase].set true
        else if index == app.WAIT-PHASE: phases[phase].get
        else if index == app.DONE:
          if radio.reads[phase + 1] != 100: throw "MIXED_UPDATE_BATCH"
          done[phase].set true
        else: done[phase].get
      return null
    return super index arguments --gid=gid --client=client

class Radio extends radio-fixture.ObservedTransport:
  phase/int := 0
  reads/List ::= [0, 0, 0, 0, 0, 0]
  closes/int := 0
  data-count/int := 0
  response-count/int := 0
  parameters/int := 0
  removes/int := 0
  enables/int := 0
  disables/int := 0
  constructor: super (esp32.Esp32Transport)
  close -> none:
    if closes != 0: return
    closes++
    super
  send packet/ByteArray -> none:
    super packet
    record packet
  send-if packet/ByteArray [allowed] -> bool:
    if not (super packet allowed): return false
    record packet
    return true
  record packet/ByteArray:
    if packet.size == 12 and packet[0] == 2 and packet[5..] == #[3, 0, 4, 0, 10, 3, 0]:
      reads[phase]++
    if packet.size >= 5 and packet[0] == 1 and packet[2] == 0x20:
      opcode := packet[1]
      if opcode == 0x36: parameters++
      if opcode == 0x37: data-count++
      if opcode == 0x38: response-count++
      if opcode == 0x3c: removes++
      if opcode == 0x39:
        if packet[4] == 1: enables++
        else: disables++
      if opcode == 6 or opcode == 8 or opcode == 9 or opcode == 10:
        throw "MIXED_UPDATE_LEGACY_COMMAND"
