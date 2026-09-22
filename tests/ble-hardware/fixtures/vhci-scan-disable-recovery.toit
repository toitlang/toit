// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.api as api
import ble.experimental.service.client as clients
import ble.experimental.service.provider as rpc
import ble.experimental.service.scanning-provider as scanning
import system
import system.containers
import .vhci-service-continuous-scan as fixture

main arguments: run arguments

// Optional fault probes are controller-specific: S3 rejects a reserved enable
// value; the original ESP32 reports Hardware Error for an extra parameter byte.
run arguments --controller-error/string?=null:
  if not [null, "rejection", "hardware"].contains controller-error: throw "INVALID_ARGUMENT"
  phases := controller-error ? 6 : 4
  with-timeout --ms=25_000:
    if arguments is Map:
      application arguments["provider"] controller-error
    else:
      provider := Provider controller-error
      provider.install
      child := containers.start containers.current {"provider": Process.current.id}
      provider.application-gid = child.gid
      try:
        if child.wait != 0: throw "SCAN_RECOVERY_CHILD_FAILED"
        provider.settled
        if provider.radios.size != phases or provider.sessions.size != phases:
          throw "SCAN_RECOVERY_WRONG_LIFETIMES"
        phases.repeat: | index/int |
          radio/Radio := provider.radios[index]
          failing := index % 2 == 0
          if not radio.closed or radio.enables != 1 or radio.drops != 0:
            throw "SCAN_RECOVERY_CONTROLLER_NOT_RELEASED"
          disables := failing ? 0 : 1
          if index == 4 and controller-error == "rejection": disables = 1
          if radio.faults != (failing ? 1 : 0) or radio.disables != disables or radio.replies != (failing ? 1 : 2):
            throw "SCAN_RECOVERY_WRONG_COMMANDS"
          if radio.rejections != (index == 4 and controller-error == "rejection" ? 1 : 0): throw "SCAN_RECOVERY_WRONG_REJECTIONS"
          if radio.hardware-errors != (index == 4 and controller-error == "hardware" ? 1 : 0): throw "SCAN_RECOVERY_WRONG_HARDWARE_ERRORS"
          stats := null
          error := catch: stats = provider.sessions[index].invoke api.SCAN-STOP []
          if error != (expected-error index controller-error): throw "SCAN_RECOVERY_WRONG_STORED_ERROR"
          if stats and (stats[0] != 0 or stats[1] != 0): throw "SCAN_RECOVERY_DROPS"
          print "SCAN_RECOVERY RADIO phase=$index closed=true enables=$(radio.enables) disables=$(radio.disables) replies=$(radio.replies) faults=$(radio.faults) rejections=$(radio.rejections) hardware-errors=$(radio.hardware-errors) native-drops=0 error=$error statistics=$stats"
        print "SCAN_RECOVERY COMPLETE child-exit=0 lifetimes=$phases controller-error=$controller-error"
      finally:
        critical-do --no-respect-deadline:
          child.close
          provider.uninstall

expected-error index/int controller-error/string? -> string?:
  if index == 0: return "SCAN_DISABLE_TRANSPORT_FAULT"
  if index == 2: return "DEADLINE_EXCEEDED"
  if index == 4:
    return controller-error == "hardware" ? "HCI_HARDWARE_ERROR" : "HCI_COMMAND_FAILED opcode=8204 status=18"
  return null

application pid/int controller-error/string?:
  client := Client --provider-pid=pid
  client.open
  try:
    (controller-error ? 6 : 4).repeat: | index/int |
      retained := []
      expected/ByteArray? := null
      stopped-at := 0
      stats := null
      error := catch:
        stats = client.scan --continuous --no-filter-duplicates --service-uuid=#[0xf0, 0xff]: | report/clients.ScanReport |
          if not fixture.target report: continue.scan true
          if not expected: expected = report.data.copy
          retained.add report.data
          system.process-stats --gc
          retained.do: if it != expected: throw "SCAN_RECOVERY_RETAINED_CHANGED"
          if retained.size < 10: continue.scan true
          stopped-at = Time.monotonic-us
          false
      elapsed := Time.monotonic-us - stopped-at
      if retained.size != 10 or error != (expected-error index controller-error):
        throw "SCAN_RECOVERY_WRONG_RESULT phase=$index reports=$(retained.size) error=$error expected=$(expected-error index controller-error) statistics=$stats"
      if index == 2 and not 3_000_000 <= elapsed < 5_000_000:
        throw "SCAN_RECOVERY_WRONG_TIMEOUT"
      if elapsed >= 5_000_000: throw "SCAN_RECOVERY_SLOW_CLEANUP"
      if stats and (stats[0] != 0 or stats[1] != 0): throw "SCAN_RECOVERY_DROPS"
      client.settled
      system.process-stats --gc
      retained.do: if it != expected: throw "SCAN_RECOVERY_RETAINED_CHANGED"
      print "SCAN_RECOVERY CLIENT phase=$index reports=10 retained=true cleanup-us=$elapsed error=$error statistics=$stats"
  finally:
    client.close

class Client extends clients.Client:
  constructor --provider-pid/int: super --provider-pid=provider-pid
  settled -> none: invoke_ 1000 null

class Provider extends scanning.Provider:
  controller-error_/string?
  application-gid/int := -1
  radios/List ::= []
  sessions/List ::= []
  constructor .controller-error_: super
  open-transport -> Radio:
    radio := Radio radios.size controller-error_
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
    if index == 1000:
      if gid != application-gid: throw "SCAN_RECOVERY_CONTROL_DENIED"
      settled
      return null
    return super index arguments --gid=gid --client=client

class Radio extends fixture.Radio:
  phase_/int
  controller-error_/string?
  faults/int := 0
  rejections/int := 0
  hardware-errors/int := 0
  constructor .phase_ .controller-error_: super
  send-if packet/ByteArray [allowed] -> bool:
    if phase_ % 2 == 0 and packet == #[1, 12, 32, 2, 0, 0]:
      if not allowed.call: return false
      faults++
      if phase_ == 0: throw "SCAN_DISABLE_TRANSPORT_FAULT"
      if phase_ == 4:
        if controller-error_ == "hardware":
          return super #[1, 12, 32, 3, 0, 0, 0] allowed
        return super #[1, 12, 32, 2, 2, 0] allowed
      // Simulate acceptance followed by loss before controller delivery. The
      // real controller remains scanning until terminal transport cleanup.
      return true
    return super packet allowed
  receive -> ByteArray:
    packet := super
    if packet.size == 7 and packet[..2] == #[4, 14] and packet[4..] == #[12, 32, 18]:
      rejections++
    if packet.size == 4 and packet[..3] == #[4, 16, 1]: hardware-errors++
    return packet
