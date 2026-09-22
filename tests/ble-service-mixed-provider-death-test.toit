// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.service.client as clients
import expect show *
import monitor
import system
import .ble-connect-isolation-test as connect
import .ble-multilink-test as links
import .ble-service-mixed-test as mixed
import .ble-service-mixed-resume-test as resume
import .ble-service-multiclient-test as wire

CRASH ::= 1000
CHECK ::= 1001
PEER ::= 1002

main:
  [false, true].do: | peripheral-first/bool |
    [false, true].do: | resumed/bool |
      (resumed ? [false, true] : [false]).do: | private/bool |
        with-timeout --ms=10_000: run peripheral-first --resumed=resumed --private=private

run peripheral-first/bool --resumed/bool=false --private/bool=false:
  process := spawn:: provider-main true peripheral-first resumed private
  central-client := Control process.id
  peripheral-client := clients.Client --provider-pid=process.id
  central-client.open --timeout=(Duration --s=1)
  peripheral-client.open --timeout=(Duration --s=1)
  entered := monitor.Latch
  unwound := monitor.Latch
  ended := monitor.Latch
  read-result := monitor.Latch
  request/clients.Request? := null
  worker/Task? := null
  reader/Task? := null
  try:
    p/clients.Session? := null
    if peripheral-first:
      p = peripheral-client.session
      p.peer
    peer := central-client.peer
    c := central-client.connect peer[0] --address-type=peer[1]
        --require-authentication=resumed
    if not p:
      p = peripheral-client.session
      p.peer
    retained := c.read 3
    expect-equals #[42] retained
    if resumed:
      expect c.security.authenticated
      expect p.security.authenticated
    worker = task::
      try:
        p.serve
            (: | current/clients.Request |
              expect-equals 12 current.handle
              request = current
              entered.set true
              try:
                (monitor.Latch).get
              finally:
                critical-do --no-respect-deadline: unwound.set true)
            (: | _ | unreachable)
            (: | _ _ | unreachable)
      finally:
        critical-do --no-respect-deadline: ended.set true
    reader = task:: read-result.set (catch: c.read 3)
    entered.get
    expect (not read-result.has-value)
    system.process-stats --gc
    expect-throw "NO_SUCH_PROCESS": central-client.crash
    with-timeout --ms=1_000:
      expect-equals "NO_SUCH_PROCESS" read-result.get
      ended.get
    expect worker.is-canceled
    expect unwound.has-value
    expect p.is-closed
    expect-equals "NO_SUCH_PROCESS" p.termination-reason
    expect-throw "GATT_REQUEST_EXPIRED": request.reply #[99]
    expect-throw "GATT_REQUESTS_CLOSED": p.value 3
    replacement c p request retained (not peripheral-first) process.id resumed private
  finally:
    if reader: reader.cancel
    if worker: worker.cancel
    central-client.close
    peripheral-client.close

replacement old-central/clients.Connection old-peripheral/clients.Session
    old-request/clients.Request retained/ByteArray peripheral-first/bool old-pid/int resumed/bool private/bool:
  process := spawn:: provider-main false peripheral-first resumed private
  expect process.id != old-pid
  central-client := Control process.id
  peripheral-client := clients.Client --provider-pid=process.id
  central-client.open --timeout=(Duration --s=1)
  peripheral-client.open --timeout=(Duration --s=1)
  ended := monitor.Latch
  worker/Task? := null
  try:
    p/clients.Session? := null
    if peripheral-first:
      p = peripheral-client.session
      p.peer
    peer := central-client.peer
    c := central-client.connect peer[0] --address-type=peer[1]
        --require-authentication=resumed
    if not p:
      p = peripheral-client.session
      p.peer
    expect-equals #[43] (c.read 3)
    if resumed:
      expect c.security.authenticated
      expect p.security.authenticated
    worker = task::
      try:
        error := catch:
          p.serve
              (: | request/clients.Request |
                expect-equals 12 request.handle
                request.reply #[44])
              (: | _ | unreachable)
              (: | _ _ | unreachable)
        if error and error != "GATT_REQUESTS_CLOSED": throw error
      finally:
        critical-do --no-respect-deadline: ended.set true
    expect-equals [1, 0] central-client.check
    system.process-stats --gc
    expect-equals #[42] retained
    expect-throw "NO_SUCH_PROCESS": old-central.read 3
    expect-throw "NO_SUCH_PROCESS": old-central.security
    expect-throw "GATT_REQUESTS_CLOSED": old-peripheral.value 3
    expect-throw "GATT_REQUESTS_CLOSED": old-peripheral.security
    expect-throw "GATT_REQUEST_EXPIRED": old-request.reply #[99]
    p.close
    ended.get
    c.disconnect
    expect-equals [1, 1] (central-client.check --closed)
  finally:
    if worker: worker.cancel
    central-client.close
    peripheral-client.close
  // Wait for the replacement provider's own assertions and normal exit.
  error/any := null
  while not error:
    error = catch: process.priority
    if not error: sleep --ms=1
  expect-equals "INVALID_ARGUMENT" error

provider-main crash/bool peripheral-first/bool resumed/bool private/bool:
  provider := resumed ? (ResumedProvider private) : Provider
  provider.install
  task::
    radio := provider.radio
    mixed.initialize radio
    host/central.Central := provider.ready.get
    if peripheral-first:
      if resumed: resume.resume-peripheral provider
      else: mixed.peripheral radio
    if resumed: resume.resume-central provider (host as resume.Host)
    else: connect.establish radio host 1 0x234 --extended-mode
    if not peripheral-first:
      if resumed: resume.resume-peripheral provider
      else: mixed.peripheral radio
    wire.sent radio 0x234 #[0x0a, 3, 0]
    wire.incoming radio 0x234 #[0x0b, crash ? 42 : 43]
    if crash:
      // Observe the actual outgoing ATT request before delivering the incoming
      // dynamic read. Neither transaction receives a response before death.
      wire.sent radio 0x234 #[0x0a, 3, 0]
      wire.incoming radio 0x235 #[0x0a, 12, 0]
      provider.pending.set true
    else:
      wire.incoming radio 0x235 #[0x0a, 12, 0]
      wire.sent radio 0x235 #[0x0b, 44]
      provider.pending.set true
      wire.disconnect radio 0x235
      wire.disconnect radio 0x234
      provider.finished.set true
  provider.uninstall --wait
  expect (not crash)
  provider.finished.get
  expect provider.radio.closed
  expect-equals 1 provider.opens
  expect-equals 1 provider.radio.closes
  if resumed:
    expect-equals 2 provider.host.connections
    provider.host.owners.values.do: | owner |
      expect (not owner.encrypted)
    provider.registry.close

class Provider extends mixed.Provider:
  pending/monitor.Latch ::= monitor.Latch
  finished/monitor.Latch ::= monitor.Latch

  create-database -> attributes.Database:
    return database false

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PEER: return [links.address 1, 1]
    if index == CRASH:
      pending.get
      exit 0
    if index == CHECK:
      pending.get
      if arguments: finished.get
      return [opens, radio.closes]
    return super index arguments --gid=gid --client=client

// Uses preloaded authenticated records. No fresh SMP pairing path is installed;
// each replacement process must enable encryption independently on both links.
class ResumedProvider extends resume.Provider:
  pending/monitor.Latch ::= monitor.Latch
  finished/monitor.Latch ::= monitor.Latch

  constructor private/bool: super private

  create-database -> attributes.Database:
    return database true

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PEER: return [addresses[0], private ? 1 : 0]
    if index == CRASH:
      pending.get
      exit 0
    if index == CHECK:
      pending.get
      if arguments: finished.get
      return [opens, radio.closes]
    return super index arguments --gid=gid --client=client

database authenticated/bool -> attributes.Database:
  result := attributes.Database.with-defaults
  result.add-service #[0xf0, 0xff]
  expect-equals 12 (result.add-characteristic #[0xf1, 0xff] --read --dynamic-read
      --authenticated=authenticated)
  return result

class Control extends clients.Client:
  constructor pid/int: super --provider-pid=pid
  crash -> none: invoke_ CRASH null
  check --closed/bool=false -> List: return invoke_ CHECK closed
  peer -> List: return invoke_ PEER null
