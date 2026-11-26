// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A reply that can't be sent fails the call instead of taking down the
  provider (see "Threats tested" in docs/sandbox-policy.md).

Quotas can be given to trusted containers too, among them the size of the
  messages they send ("message-bytes"). A trusted provider P with such a
  quota serves sandboxed clients, and the size of its replies depends on
  the arguments. Before the fix, a sandboxed client that asked for a reply
  larger than P's quota made the reply send throw QUOTA_EXCEEDED in P's RPC
  processing task, which terminated P, and every other client lost the
  service. Now the call fails with QUOTA_EXCEEDED and P keeps serving.

The same holds for a provider in a sandbox (Y, granted to provide
  services) with that quota: its trusted client's call fails once the
  broker gives up retrying, and Y keeps serving.
*/

import expect show *
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient TAG-UNTRUSTED-PROVIDER

ROLE-KEY ::= "role"
QUOTAS ::= {"message-bytes": 2_000}
SMALL ::= 10
LARGE ::= 4_000

interface SizeService:
  static SELECTOR ::= ServiceSelector
      --uuid="8e4c2b1a-7d3f-4a5e-9b6c-0f1e2d3c4b52"
      --major=1
      --minor=0

  // Returns a byte array of the given $size.
  make size/int -> ByteArray
  static MAKE-INDEX ::= 0

class SizeClient extends ServiceClient implements SizeService:
  constructor selector/ServiceSelector=SizeService.SELECTOR:
    super selector

  make size/int -> ByteArray:
    return invoke_ SizeService.MAKE-INDEX size

class SizeProvider extends ServiceProvider implements SizeService ServiceHandler:
  constructor:
    super "test/size" --major=1 --minor=0
    provides SizeService.SELECTOR --handler=this

  accepts-untrusted-clients -> bool:
    return true

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == SizeService.MAKE-INDEX: return make arguments
    unreachable

  make size/int -> ByteArray:
    return ByteArray size: it

main arguments:
  if arguments is Map:
    role := arguments[ROLE-KEY]
    if role == "provider":
      (SizeProvider).install
      while true: sleep --ms=1_000
    else if role == "client":
      run-client
    else:
      throw "Unknown role: $role"
    return
  run-driver

check client/SizeClient -> none:
  expect-equals SMALL (client.make SMALL).size
  expect-throw "QUOTA_EXCEEDED": client.make LARGE
  expect-equals SMALL (client.make SMALL).size

// The sandboxed client of the trusted provider.
run-client -> none:
  client := SizeClient
  client.open --timeout=(Duration --s=5)
  check client
  client.close

run-driver:
  // A trusted provider with a message size quota.
  p-stopped := false
  p := containers.start containers.current {ROLE-KEY: "provider"}
      --quotas=QUOTAS
      --on-stopped=:: p-stopped = true
  trusted := SizeClient
  trusted.open --timeout=(Duration --s=5)
  expect-equals SMALL (trusted.make SMALL).size

  sandboxed := containers.start containers.current {ROLE-KEY: "client"} --untrusted
      --services=[SizeService.SELECTOR.uuid]
  expect-equals 0 sandboxed.wait
  expect-not p-stopped
  // The trusted client still gets service; a trusted client that asks for
  // a reply that is too large gets the same error.
  check trusted
  expect-not p-stopped
  trusted.close
  p.stop

  // A provider in a sandbox with a message size quota. It retries the
  // reply (it can't tell a reply that is too large from one to a full
  // mailbox) before the call fails.
  y-stopped := false
  y := containers.start containers.current {ROLE-KEY: "provider"}
      --untrusted
      --quotas=QUOTAS
      --may-provide-services
      --on-stopped=:: y-stopped = true
  y-client := SizeClient (SizeService.SELECTOR.restrict.allow --tag=TAG-UNTRUSTED-PROVIDER)
  y-client.open --timeout=(Duration --s=5)
  check y-client
  expect-not y-stopped
  y-client.close
  y.stop
  print "OK"
