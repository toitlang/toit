// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the sandbox heap floor applies to starting a sandboxed container,
  and that a sandboxed program that keeps running out of memory is restarted
  with a growing delay.

Before, the floor was checked only when a sandboxed heap grew: a sandboxed
  container that was started (or restarted after it died of OUT_OF_MEMORY)
  took its initial memory however little the system had left. On a device a
  worker was restarted 4 times in 5 seconds, each time with a new initial
  heap, while the system heap was at 1-5 KB.

Now (on the host with a simulated system heap of 600 KB, a 400 KB floor and
  -Xsandbox_start_bytes=150000): a sandbox starts while nothing holds the
  heap; a second one is refused with QUOTA_EXCEEDED while a first holds
  about 100 KB (a trusted container still starts); after the first stopped,
  it starts again. A sandboxed run that ran out of memory makes the next
  sandboxed start of its program wait 1 s after the failure, the next one 2
  s. Without the floor nothing changes: every start is admitted.
*/

import expect show *
import .sandbox-util show *

PROGRAM ::= """
import monitor
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient

interface ReadyService:
  static SELECTOR ::= ServiceSelector
      --uuid="3d0a8c6e-6a51-4c0f-9f1e-1c2b7a4e5d60"
      --major=1
      --minor=0
  ready size/int -> none
  static READY-INDEX ::= 0

class ReadyClient extends ServiceClient implements ReadyService:
  static SELECTOR ::= ReadyService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    super selector
  ready size/int -> none:
    invoke_ ReadyService.READY-INDEX size

class ReadyProvider extends ServiceProvider implements ServiceHandler:
  latch := monitor.Latch
  constructor:
    super "test/ready" --major=1 --minor=0
    provides ReadyService.SELECTOR --handler=this
  accepts-untrusted-clients -> bool:
    return true
  handle index/int arguments/any --gid/int --client/int -> any:
    latch.set arguments
    return null

main args:
  if args is Map:
    role := args["role"]
    if role == "small": return
    if role == "hold": hold
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

  // A sandbox holds about 100 KB of the 200 KB above the floor: the next
  // sandbox can't start (it needs 150 KB above the floor), a trusted
  // container can.
  holder := containers.start containers.current {"role": "hold"} --untrusted --quotas={"heap": 2_000_000}
      --services=[ReadyService.SELECTOR.uuid]
  print "holder ready: \$(provider.latch.get)"
  print "small while held: \$(start "small" --untrusted)"
  print "trusted while held: \$(start "small" --untrusted=false)"
  holder.stop
  holder.wait
  print "small after: \$(start "small" --untrusted)"

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
        --services=[ReadyService.SELECTOR.uuid]
        --quotas={"heap": 2_000_000}
    return container.wait
  return exception

/** Grows the heap by about 100 KB, tells the driver, and keeps it. */
hold -> none:
  client := ReadyClient
  client.open
  list := []
  100.repeat: list.add (ByteArray 1_000)
  client.ready list.size
  sleep --ms=60_000
  print list.size

/** Allocates until it runs out of memory, and dies of it. */
die -> none:
  list := []
  while true: list.add (ByteArray 1_000)
"""

FLAGS ::= ["-Xsandbox_heap_floor=400000", "-Xsandbox_system_heap=600000", "-Xsandbox_start_bytes=150000"]

main args:
  toit-run := args[0]
  with-tmp-directory: | dir |
    source := "$dir/sandbox-start-floor-main.toit"
    write-file source PROGRAM

    output := run toit-run source FLAGS ["floor"]
    expect-equals [
      "small: 0",
      "holder ready: 100",
      "small while held: QUOTA_EXCEEDED",
      "trusted while held: 0",
      "small after: 0",
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
        or line.starts-with "die":
      result.add line
  return result
