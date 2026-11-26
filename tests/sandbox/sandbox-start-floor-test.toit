// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the sandbox heap floor at the start of a sandboxed container: the
  order of the floor's levels, the collection before a refusal, and the
  growing delay of a sandboxed program that keeps running out of memory.

The levels of the free system heap (docs/sandbox-policy.md, "Quotas"):
  sandboxed heaps stop growing at the floor plus the growth headroom, a
  sandboxed start needs the floor plus the start bytes (at most the
  headroom), and messages of sandboxes stop at the floor. Here (host,
  simulated system heap of 600 KB, 300 KB floor, -Xsandbox_start_bytes=
  150000, so a headroom of 150 KB): heaps stop growing at 450 KB free.

- A sandbox that grows as far as it can (about 150 KB) leaves room for the
  start of another (and of a trusted container). Before, sandboxed heaps
  grew down to the floor itself (300 KB here), and the start was refused.
- Messages queued at the holder (50 KB, from the trusted driver) take the
  room: a sandboxed start is refused with QUOTA_EXCEEDED; a trusted one
  still starts. After the holder stopped, the sandbox starts again.
- A sandbox that grew and dropped what it held (its heap pages are free,
  but not given back), plus the same messages: the start collects every
  process's garbage first and then starts. Before, it was refused.
- A sandboxed run that ran out of memory makes the next sandboxed start of
  its program wait 1 s after the failure, the next one 2 s.
- Without the floor nothing changes: every start is admitted.
*/

import expect show *
import .sandbox-util show *

PROGRAM ::= """
import monitor
import system
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient

interface ReadyService:
  static SELECTOR ::= ServiceSelector
      --uuid="3d0a8c6e-6a51-4c0f-9f1e-1c2b7a4e5d60"
      --major=1
      --minor=0
  ready size/int pid/int -> none
  static READY-INDEX ::= 0

class ReadyClient extends ServiceClient implements ReadyService:
  static SELECTOR ::= ReadyService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    super selector
  ready size/int pid/int -> none:
    invoke_ ReadyService.READY-INDEX [size, pid]

class ReadyProvider extends ServiceProvider implements ServiceHandler:
  channel := monitor.Channel 1
  constructor:
    super "test/ready" --major=1 --minor=0
    provides ReadyService.SELECTOR --handler=this
  accepts-untrusted-clients -> bool:
    return true
  handle index/int arguments/any --gid/int --client/int -> any:
    channel.send arguments
    return null

SPIN-MS ::= 5_000

main args:
  if args is Map:
    role := args["role"]
    if role == "small": return
    if role == "hold": hold --keep
    if role == "garbage": hold --no-keep
    if role == "die": die
    return
  floor := args.size > 0
  provider := ReadyProvider
  provider.install

  if not floor:
    // Without the floor every start is admitted.
    print "die: \$(start "die" --untrusted)"
    print "die: \$(start "die" --untrusted)"
    provider.uninstall
    return

  print "small: \$(start "small" --untrusted)"

  // A sandbox holds as much as it can: its growth leaves room for a start.
  holder := start-holder "hold"
  ready := provider.channel.receive
  print "holder ready: \$(ready[0] > 100 and ready[0] <= 150)"
  print "small while held: \$(start "small" --untrusted)"
  print "trusted while held: \$(start "small" --untrusted=false)"
  // Messages queued at the holder take the room (it spins and doesn't take
  // them): a sandboxed start is refused, a trusted one isn't.
  print "filled: \$(fill ready[1])"
  print "small while filled: \$(start "small" --untrusted)"
  print "trusted while filled: \$(start "small" --untrusted=false)"
  provider.channel.receive  // Done spinning.
  stop holder ready[1]
  print "small after: \$(start "small" --untrusted)"

  // A sandbox grew and dropped it: the start collects its garbage first.
  garbage := start-holder "garbage"
  ready = provider.channel.receive
  sleep --ms=200  // It drops what it held.
  print "garbage ready: \$(ready[0] > 100 and ready[0] <= 150)"
  print "filled: \$(fill ready[1])"
  print "small after collecting: \$(start "small" --untrusted)"
  provider.channel.receive
  stop garbage ready[1]

  // A sandboxed run that runs out of memory: the next start waits 1 s.
  print "die 1: \$(start "die" --untrusted)"
  print "die 1 again: \$(start "die" --untrusted)"
  sleep --ms=1_100
  print "die 2: \$(start "die" --untrusted)"
  // The second failing run in a row: the program waits 2 s.
  print "small after die 2: \$(start "small" --untrusted)"
  sleep --ms=1_100
  print "small 1.1 s after die 2: \$(start "small" --untrusted)"
  sleep --ms=1_100
  print "small 2.2 s after die 2: \$(start "small" --untrusted)"
  provider.uninstall

/** Starts the role and returns its exit code, or the error of the start. */
start role/string --untrusted/bool -> any:
  exception := catch:
    container := containers.start containers.current {"role": role}
        --untrusted=untrusted
        --quotas={"heap": 2_000_000}
    return container.wait
  return exception

/**
Stops the [container] and waits until its process [pid] is gone (the
  container's stop doesn't wait for that).
*/
stop container/containers.Container pid/int -> none:
  container.stop
  container.wait
  while system.process-stats container.gid pid: sleep --ms=10

start-holder role/string -> containers.Container:
  return containers.start containers.current {"role": role}
      --untrusted
      --quotas={"heap": 2_000_000, "run-time-ms": 10_000}

/** Queues five 10 KB messages at the process [pid]; returns how many it took. */
fill pid/int -> int:
  sent := 0
  5.repeat:
    if process-send_ pid 100 (ByteArray 10_000): sent++
  return sent

/**
Grows the heap in 1 KB byte arrays until it can't, tells the driver how
  many it kept (it drops 10, so that it can call) and its pid, spins for a
  while without taking messages or allocating, and tells the driver again.
  Keeps the arrays if \$keep, else drops them first.
*/
hold --keep/bool -> none:
  client := ReadyClient
  client.open
  list := []
  catch: while true: list.add (ByteArray 1_000)
  // Room for the call below.
  10.repeat: if not list.is-empty: list.remove-last
  size := list.size
  client.ready size Process.current.id
  // Dropped after the call, so that no collection gives the pages back
  // before the driver starts the next sandbox (it spins without
  // allocating).
  if not keep: list = []
  deadline := Time.monotonic-us + SPIN-MS * 1_000
  while Time.monotonic-us < deadline: null
  // Done: the driver stops it (a process that spins is only killed when it
  // is preempted).
  client.ready -1 Process.current.id
  sleep --ms=60_000
  print list.size

/** Allocates until it runs out of memory, and dies of it. */
die -> none:
  list := []
  while true: list.add (ByteArray 1_000)
"""

FLAGS ::= ["-Xsandbox_heap_floor=300000", "-Xsandbox_system_heap=600000", "-Xsandbox_start_bytes=150000"]

main args:
  toit-run := args[0]
  with-tmp-directory: | dir |
    source := "$dir/sandbox-start-floor-main.toit"
    write-file source PROGRAM

    output := run toit-run source FLAGS ["floor"]
    expect-equals [
      "small: 0",
      "holder ready: true",
      "small while held: 0",
      "trusted while held: 0",
      "filled: 5",
      "small while filled: QUOTA_EXCEEDED",
      "trusted while filled: 0",
      "small after: 0",
      "garbage ready: true",
      "filled: 5",
      "small after collecting: 0",
      "die 1: 1",
      "die 1 again: QUOTA_EXCEEDED",
      "die 2: 1",
      "small after die 2: QUOTA_EXCEEDED",
      "small 1.1 s after die 2: QUOTA_EXCEEDED",
      "small 2.2 s after die 2: 0",
    ] (outcomes output)
    expect (output.contains "[sandbox start refused: ")

    output = run toit-run source [] []
    expect-equals ["die: 1", "die: 1"] (outcomes output)
    expect-not (output.contains "[sandbox start refused: ")
  print "sandbox-start-floor-test OK"

run toit-run/string source/string flags/List arguments/List -> string:
  result := run-process [toit-run] + flags + [source] + arguments --timeout-ms=60_000
  print result.output
  expect-equals 0 result.exit-code
  return result.output

/** The driver's outcome lines. */
outcomes output/string -> List:
  result := []
  output.split "\n": | line/string |
    if line.starts-with "small" or line.starts-with "holder" or line.starts-with "trusted"
        or line.starts-with "die" or line.starts-with "filled" or line.starts-with "garbage":
      result.add line
  return result
