// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.api.service-discovery show ServiceDiscoveryServiceClient
import .sandbox

/**
A busy sandbox doesn't starve the other processes.

The untrusted container runs, in turn: a tight loop (backward branches),
  long primitives on the largest byte arrays and strings it may allocate,
  deep recursion, and many tasks that never block. Meanwhile the driver
  pings the trusted sibling and asks the system process for discoveries
  and records the worst latencies.

The untrusted process must survive (it is preempted, not killed: none of
  the phases runs for max_run_time_us without returning to the scheduler)
  and the worst ping latency must stay well below a second.

On a host the VM has a scheduler thread per core, so the sandbox can only
  take one of them; run the test pinned to a single core (taskset -c 0) to
  see the preemption at work.
*/

PHASE-US ::= 1_500_000
LATENCY-LIMIT-US ::= 1_000_000

probe client/SiblingClient -> none:
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  pings := 0
  max-ping := 0
  max-discover := 0
  start := Time.monotonic-us
  while Time.monotonic-us - start < 4 * PHASE-US:
    t := Time.monotonic-us
    expect-equals 2 (client.ping 1)
    elapsed := Time.monotonic-us - t
    if elapsed > max-ping: max-ping = elapsed
    t = Time.monotonic-us
    discovery.discover "no-such-service" --no-wait
    elapsed = Time.monotonic-us - t
    if elapsed > max-discover: max-discover = elapsed
    pings++
    sleep --ms=10
  discovery.close
  print "driver: $pings pings, worst ping $(max-ping / 1000) ms, worst discovery $(max-discover / 1000) ms"
  expect max-ping < LATENCY-LIMIT-US
  expect max-discover < LATENCY-LIMIT-US

recurse n/int -> int:
  if n == 0: return 0
  return 1 + (recurse n - 1)

main args:
  sandbox-test args --error="DONE" --during=(:: probe it): | arguments/Map |
    // Phase 1: a tight loop.
    start := Time.monotonic-us
    x := 0
    while Time.monotonic-us - start < PHASE-US: x++

    // Phase 2: long primitives on large objects. Each of these is a single
    // primitive call that the scheduler can't interrupt.
    worst := 0
    big := ByteArray 16_000_000: 'a'
    start = Time.monotonic-us
    while Time.monotonic-us - start < PHASE-US:
      [
        :: big.index-of 'b',
        :: big.replace 1 big 0 (big.size - 1),
        :: big.to-string,
        :: big.hash-code,
        :: big.to-string + "x",
      ].do: | operation/Lambda |
        t := Time.monotonic-us
        operation.call
        elapsed := Time.monotonic-us - t
        if elapsed > worst: worst = elapsed
    big = #[]

    // Phase 3: deep recursion.
    start = Time.monotonic-us
    while Time.monotonic-us - start < PHASE-US / 2:
      recurse 300

    // Phase 4: many tasks that only yield.
    stop := false
    100.repeat:
      task::
        while not stop: yield
    sleep --ms=(PHASE-US / 2000)
    stop = true

    print "sandbox: loop $x, worst primitive $(worst / 1000) ms"
    throw "DONE"
