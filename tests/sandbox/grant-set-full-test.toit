// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that a full allowed-target set (64 grants) makes service discovery
  fail with QUOTA_EXCEEDED instead of silently evicting an older grant.

The untrusted container first discovers and uses an anchor service. Then
  it discovers a service with more providers (each in its own process)
  than there is room for. The discovery fails, and the capability for the
  anchor still works.
*/

import expect show *
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient
import system.api.service-discovery show ServiceDiscoveryServiceClient

ROLE-KEY ::= "role"

// More providers than the allowed-target set has room for.
PROVIDER-COUNT ::= 65

interface PidService:
  static ANCHOR-SELECTOR ::= ServiceSelector
      --uuid="b0c6a3f2-5e1d-4c8b-9a7f-3d2e1c0b9a01"
      --major=1
      --minor=0
  static CROWD-SELECTOR ::= ServiceSelector
      --uuid="b0c6a3f2-5e1d-4c8b-9a7f-3d2e1c0b9a02"
      --major=1
      --minor=0

  pid -> int
  static PID-INDEX ::= 0

class PidClient extends ServiceClient implements PidService:
  constructor selector/ServiceSelector:
    super selector

  pid -> int:
    return invoke_ PidService.PID-INDEX null

class PidProvider extends ServiceProvider implements PidService ServiceHandler:
  constructor selector/ServiceSelector:
    super "test/pid" --major=1 --minor=0
    provides selector --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PidService.PID-INDEX: return pid
    unreachable

  pid -> int:
    return Process.current.id

provide selector/ServiceSelector -> none:
  (PidProvider selector).install
  while true: sleep --ms=100

// Starts the providers one after the other, so the system process doesn't
// get too many requests at once.
provide-crowd count/int -> none:
  (PidProvider PidService.CROWD-SELECTOR).install
  if count > 1: spawn:: provide-crowd count - 1
  while true: sleep --ms=100

main arguments:
  if arguments is Map:
    role := arguments[ROLE-KEY]
    if role == "anchor":
      provide PidService.ANCHOR-SELECTOR
    else if role == "crowd":
      provide-crowd PROVIDER-COUNT
    else if role == "untrusted":
      run-untrusted
    else:
      throw "Unknown role: $role"
    return
  run-driver

run-driver:
  anchor := containers.start containers.current {ROLE-KEY: "anchor"}
  crowd := containers.start containers.current {ROLE-KEY: "crowd"}

  // Wait until all providers are registered.
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  deadline := Time.monotonic-us + 20_000_000
  while true:
    result := discovery.discover PidService.CROWD-SELECTOR.uuid --wait=false
    count := (result and result[0]) ? result[0].size / 7 : 0
    if count == PROVIDER-COUNT: break
    expect Time.monotonic-us < deadline
    sleep --ms=20
  discovery.close
  anchor-client := PidClient PidService.ANCHOR-SELECTOR
  anchor-client.open --timeout=(Duration --s=5)
  anchor-client.close

  untrusted := containers.start containers.current {ROLE-KEY: "untrusted"}
      --untrusted
  expect-equals 0 untrusted.wait

  anchor.stop
  crowd.stop
  print "OK"

run-untrusted:
  anchor := PidClient PidService.ANCHOR-SELECTOR
  anchor.open
  anchor-pid := anchor.pid

  discovery := ServiceDiscoveryServiceClient
  discovery.open
  expect-throw "QUOTA_EXCEEDED":
    discovery.discover PidService.CROWD-SELECTOR.uuid --wait=false
  discovery.close

  // The earlier grant was not evicted.
  expect-equals anchor-pid anchor.pid
  anchor.close
  print "untrusted done"
