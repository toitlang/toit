// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.provider as rpc
import ble.experimental.service.scanning-provider as scanning
import monitor
import system
import system.containers

main arguments: run arguments

run arguments --minimum-us/int=65_000_000:
  if not 65_000_000 <= minimum-us <= 7_200_000_000: throw "INVALID_ARGUMENT"
  with-timeout --ms=(minimum-us / 1_000 + 20_000):
    if arguments is Map:
      application arguments["provider"] minimum-us
    else:
      provider := Provider
      provider.install
      child := containers.start containers.current {"provider": Process.current.id}
      provider.application-gid = child.gid
      try:
        if child.wait != 0: throw "CONTINUOUS_SCAN_CHILD_FAILED"
        provider.settled
        if provider.radios.size != 4 or provider.sessions.size != 4 or not provider.wait-proven:
          throw "CONTINUOUS_SCAN_WRONG_LIFETIMES"
        4.repeat: | index/int |
          radio/Radio := provider.radios[index]
          if not radio.closed or radio.enables != 1 or radio.disables != 1 or radio.replies != 2:
            throw "CONTINUOUS_SCAN_INCOMPLETE_CLEANUP"
          stats := provider.sessions[index].invoke api.SCAN-STOP []
          if stats[0] != 0 or stats[1] != 0 or radio.drops != 0:
            throw "CONTINUOUS_SCAN_DROPPED_REPORTS"
          elapsed := radio.disabled-us - radio.enabled-us
          if index == 0 and elapsed <= 60_000_000: throw "CONTINUOUS_SCAN_FINITE_LIMIT_NOT_CROSSED"
          if index == 0 and elapsed < minimum-us: throw "CONTINUOUS_SCAN_DURATION_NOT_REACHED"
          print "CONTINUOUS_SCAN RADIO phase=$index enables=1 disables=1 replies=2 native-drops=0 scan-us=$elapsed statistics=$stats"
        print "CONTINUOUS_SCAN COMPLETE child-exit=0 lifetimes=4 waiting-proven=true"
      finally:
        critical-do --no-respect-deadline:
          child.close
          provider.uninstall

application pid/int minimum-us/int:
  client := Client --provider-pid=pid
  client.open
  try:
    if not client.capabilities.continuous-scanning: throw "CONTINUOUS_SCAN_UNSUPPORTED"
    collect client "past-finite-limit" --minimum-us=minimum-us
    client.settled
    entered := monitor.Latch
    ended := monitor.Latch
    hold := monitor.Latch
    scanner := task::
      try:
        client.scan --continuous --no-filter-duplicates --service-uuid=#[0xf0, 0xff]: | report/clients.ScanReport |
          if not target report: continue.scan true
          entered.set report.data.copy
          hold.get
          true
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      retained/ByteArray := entered.get
      expected := retained.copy
      scanner.cancel
      ended.get
      client.settled
      system.process-stats --gc
      if retained != expected: throw "CONTINUOUS_SCAN_RETAINED_CHANGED"
      print "CONTINUOUS_SCAN CANCELED retained=true"
    finally:
      scanner.cancel
    cancel-waiting client
    collect client "reopened"
    client.settled
  finally:
    client.close

target report/clients.ScanReport -> bool:
  return report.address-type == 0 and report.address == #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]

collect client/Client phase/string --minimum-us/int=0:
  retained := []
  expected/ByteArray? := null
  start := Time.monotonic-us
  reports := 0
  stats := client.scan --continuous --duration=(Duration --ms=1)
      --no-filter-duplicates
      --service-uuid=#[0xf0, 0xff]: | report/clients.ScanReport |
    if not target report: continue.scan true
    if expected == null:
      expected = report.data.copy
      // Measure from received traffic, after the controller enabled scanning.
      start = Time.monotonic-us
    if report.data != expected: throw "CONTINUOUS_SCAN_DATA_CHANGED"
    reports++
    if retained.size < 10: retained.add report.data
    system.process-stats --gc
    retained.do: if it != expected: throw "CONTINUOUS_SCAN_RETAINED_CHANGED"
    if reports % 1_000 == 0:
      print "CONTINUOUS_SCAN PROGRESS phase=$phase reports=$reports elapsed-us=$(Time.monotonic-us - start) retained=true"
    reports < 10 or Time.monotonic-us - start < minimum-us
  elapsed := Time.monotonic-us - start
  if retained.size != 10 or elapsed <= 1_000: throw "CONTINUOUS_SCAN_ENDED_EARLY"
  if stats[0] != 0 or stats[1] != 0: throw "CONTINUOUS_SCAN_DROPPED_REPORTS"
  print "CONTINUOUS_SCAN COLLECT phase=$phase reports=$reports elapsed-us=$elapsed retained=true statistics=$stats"

cancel-waiting client/Client:
  ended := monitor.Latch
  callbacks := 0
  scanner := task::
    try:
      // No peer in this fixture advertises this 128-bit service UUID.
      client.scan --continuous --service-uuid=#[0x19, 0x91, 0x28, 0x62, 0x73, 0x54, 0x49, 0xe2, 0xb1, 0x65, 0x84, 0x16, 0x02, 0x63, 0x42, 0x17]:
        callbacks++
        throw "CONTINUOUS_SCAN_UNEXPECTED_SERVICE"
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    client.await-report-wait
    scanner.cancel
    ended.get
    client.settled
    if callbacks != 0: throw "CONTINUOUS_SCAN_WAIT_DELIVERED"
    print "CONTINUOUS_SCAN WAIT_CANCELED callbacks=0"
  finally:
    scanner.cancel

class Client extends clients.Client:
  constructor --provider-pid/int: super --provider-pid=provider-pid
  settled -> none: invoke_ 1000 null
  await-report-wait -> none: invoke_ 1001 null

class Provider extends scanning.Provider:
  application-gid/int := -1
  radios/List ::= []
  sessions/List ::= []
  waiting_/int := 0
  wait-proven/bool := false
  constructor: super
  open-transport -> Radio:
    radio := Radio
    radios.add radio
    return radio
  create-scan client/int arguments/List -> rpc.Session:
    session := super client arguments
    sessions.add session
    return session
  settled -> none:
    with-timeout --ms=5_000:
      sessions.do: while not it.is-released: sleep --ms=1
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 1000 or index == 1001:
      if gid != application-gid: throw "CONTINUOUS_SCAN_CONTROL_DENIED"
      if index == 1000:
        settled
      else:
        with-timeout --ms=5_000:
          while sessions.size != 3 or radios.size != 3 or waiting_ != 1 or radios.last.replies != 1:
            sleep --ms=1
        wait-proven = true
      return null
    if index == api.SCAN-NEXT:
      waiting_++
      try:
        return super index arguments --gid=gid --client=client
      finally:
        critical-do --no-respect-deadline: waiting_--
    return super index arguments --gid=gid --client=client

class Radio extends esp32.Esp32Transport:
  enables/int := 0
  disables/int := 0
  replies/int := 0
  drops/int := -1
  closed/bool := false
  enabled-us/int := 0
  disabled-us/int := 0
  constructor: super
  send-if packet/ByteArray [allowed] -> bool:
    sent := super packet allowed
    if sent and packet.size == 6 and packet[..4] == #[1, 12, 32, 2]:
      if packet[4] == 1:
        enables++
        enabled-us = Time.monotonic-us
      else:
        disables++
        disabled-us = Time.monotonic-us
    return sent
  receive -> ByteArray:
    packet := super
    if packet.size == 7 and packet[0] == 4 and packet[1] == 14 and packet[4..6] == #[12, 32] and packet[6] == 0:
      replies++
    return packet
  close -> none:
    if closed: return
    sample := diagnostics
    if sample: drops = sample.scan-drops
    super
    closed = true
