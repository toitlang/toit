// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient
import .sandbox

/**
A sandbox that may talk to a trusted process can't forge the replies to
  that process' pending requests to other processes, nor cancel them.

The untrusted container provides a service. The driver calls it, which
  grants the sandbox the capability to send to the driver (so it can
  reply). The sandbox then floods the driver with SYSTEM_RPC_REPLY
  messages for every plausible request id (ids are sequential) and with
  SYSTEM_RPC_NOTIFY_RESOURCE messages for guessed client ids and
  handles, and floods the sibling with SYSTEM_RPC_CANCEL messages for the
  same ids. Meanwhile the driver has slow requests pending at the sibling
  and keeps pinging it: every reply it gets must be the real one, and no
  request may be canceled.
*/

interface ForgeService:
  static SELECTOR ::= ServiceSelector
      --uuid="5a1b8e0e-3f0c-4d0e-9d6a-2b7e0d5c9a12"
      --major=1
      --minor=0

  // Starts the forgery against the caller.
  start -> none
  static START-INDEX ::= 0

class ForgeClient extends ServiceClient implements ForgeService:
  constructor:
    super ForgeService.SELECTOR

  start -> none:
    invoke_ ForgeService.START-INDEX null

class ForgeProvider extends ServiceProvider implements ForgeService ServiceHandler:
  sibling/int
  done := false

  constructor .sibling:
    super "test/sandbox/forge" --major=1 --minor=0
    provides ForgeService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ForgeService.START-INDEX:
      driver := pid --client=client
      task:: forge driver
      return null
    unreachable

  start -> none:
    unreachable

  forge driver/int -> none:
    forged := 0
    deadline := Time.monotonic-us + 1_500_000
    while Time.monotonic-us < deadline:
      200.repeat: | id |
        catch:
          process-send_ driver SYSTEM-RPC-REPLY_ [id, false, "forged"]
          process-send_ driver SYSTEM-RPC-REPLY_ [id, true, "forged", null]
          process-send_ driver SYSTEM-RPC-NOTIFY-RESOURCE_ [id, id * 2 + 1, "forged"]
          process-send_ sibling SYSTEM-RPC-CANCEL_ [id]
          forged++
      yield
    print "sandbox: sent $forged rounds of forged messages"
    done = true

probe client/SiblingClient -> none:
  forge := ForgeClient
  forge.open --timeout=(Duration --s=5)
  // Keep requests pending at the sibling while the forgery runs.
  slow-results := []
  3.repeat: | i |
    task:: slow-results.add (client.slow 1_000 + i)
  forge.start
  deadline := Time.monotonic-us + 1_500_000
  while Time.monotonic-us < deadline:
    expect-equals 8 (client.ping 7)
  while slow-results.size < 3: sleep --ms=10
  expect-equals [1001, 1002, 1003] slow-results.sort
  forge.close

main args:
  sandbox-test args --error="DONE" --during=(:: probe it): | arguments/Map |
    sibling := discover-pid SiblingService.SELECTOR.uuid
    provider := ForgeProvider sibling
    provider.install
    deadline := Time.monotonic-us + 6_000_000
    while not provider.done and Time.monotonic-us < deadline: sleep --ms=50
    // Give the driver time to check its replies.
    sleep --ms=1_000
    provider.uninstall
    if not provider.done: throw "NOT_CALLED"
    throw "DONE"
