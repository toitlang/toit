// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Characterizes the scope of the mailbox quotas (see "Threats tested" in
  docs/sandbox-policy.md). This test documents two open design gaps; it
  asserts the current behavior and must be updated when they are closed.

The per-sender mailbox quota of a sandbox (max_mailbox_messages,
  max_mailbox_bytes) is enforced per receiver, on the sum of the messages
  of all messaging-restricted senders in that receiver's mailbox:

1. It isn't a per-sender budget over all receivers: a sandbox fills every
  receiver it may send to (up to 64 granted providers and the system
  process) up to the quota. Here sandbox A fills two providers that don't
  process their messages.
2. It isn't per sender either: once sandbox A filled a provider's
  mailbox, sandbox B can't send a single message to that provider until
  the provider drains its mailbox.
*/

import expect show *
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler
import system.api.service-discovery show ServiceDiscoveryServiceClient

ROLE-KEY ::= "role"
USER-MESSAGE-TYPE ::= 100
QUOTA ::= 16
QUOTAS ::= {"mailbox-messages": QUOTA}

interface StuckService:
  static SELECTOR ::= ServiceSelector
      --uuid="b0c6a3f2-5e1d-4c8b-9a7f-3d2e1c0b9a21"
      --major=1
      --minor=0

class StuckProvider extends ServiceProvider implements StuckService ServiceHandler:
  constructor:
    super "test/stuck" --major=1 --minor=0
    provides StuckService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    unreachable

main arguments:
  if arguments is Map:
    role := arguments[ROLE-KEY]
    if role == "provider":
      (StuckProvider).install
      // Never process another message.
      while true: null
    else if role == "a":
      run-a
    else if role == "b":
      run-b
    else:
      throw "Unknown role: $role"
    return
  run-driver

provider-pids -> List:
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  try:
    while true:
      result := discovery.discover StuckService.SELECTOR.uuid --wait=false
      if result[0] and result[0].size == 14: return [result[0][0], result[0][7]]
      sleep --ms=10
  finally:
    discovery.close

run-driver:
  providers := [
    containers.start containers.current {ROLE-KEY: "provider"},
    containers.start containers.current {ROLE-KEY: "provider"},
  ]
  provider-pids
  a := containers.start containers.current {ROLE-KEY: "a"} --untrusted --quotas=QUOTAS
  expect-equals 0 a.wait
  b := containers.start containers.current {ROLE-KEY: "b"} --untrusted --quotas=QUOTAS
  expect-equals 0 b.wait
  providers.do: it.stop
  print "OK"

fill pid/int -> int:
  sent := 0
  exception := catch:
    1000.repeat:
      process-send_ pid USER-MESSAGE-TYPE sent
      sent++
  expect-equals "QUOTA_EXCEEDED" exception
  return sent

run-a:
  // Each receiver takes (at least) QUOTA messages from us: the quota is not
  // a budget over all receivers. A provider that is discoverable may still
  // be finishing its installation, and then processes a few of our
  // messages before it gets stuck.
  counts := provider-pids.map: fill it
  counts.do: expect it >= QUOTA

run-b:
  // Sandbox A's messages take up our quota at the providers.
  counts := provider-pids.map: fill it
  expect-equals [0, 0] counts
