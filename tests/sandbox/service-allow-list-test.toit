// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
The per-container service allow-list: a sandbox discovers and opens only
  the services its launch policy lists (`containers.start --services`),
  besides discovery and printing; "all" lets it use every provider that
  accepts sandboxed clients.
Three trusted providers serve sandboxed clients (X, Y and Z). Sandboxes
  with different lists see different providers; a sandbox without a list
  sees none but can still print. A sandbox that sends the open request to
  a provider's pid without discovery (as its own core library could) is
  stopped by the VM, because only discovery grants it the right to send to
  that pid. Discoveries that wait for a provider that starts later are only
  answered for listed services. Malformed lists are refused at start.
*/

import expect show *
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient
import .sandbox show provider-ids open-without-discovery

interface PingService:
  static X ::= ServiceSelector --uuid="6a0f1c2e-41d3-4b8a-9e57-0c1d2e3f4a01" --major=1 --minor=0
  static Y ::= ServiceSelector --uuid="6a0f1c2e-41d3-4b8a-9e57-0c1d2e3f4a02" --major=1 --minor=0
  static Z ::= ServiceSelector --uuid="6a0f1c2e-41d3-4b8a-9e57-0c1d2e3f4a03" --major=1 --minor=0
  ping value/int -> int
  static PING-INDEX ::= 0

class PingClient extends ServiceClient implements PingService:
  constructor selector/ServiceSelector:
    super selector
  ping value/int -> int:
    return invoke_ PingService.PING-INDEX value

class PingProvider extends ServiceProvider implements PingService ServiceHandler:
  constructor selector/ServiceSelector:
    super "test/ping" --major=1 --minor=0
    provides selector --handler=this
  accepts-untrusted-clients -> bool:
    return true
  handle index/int arguments/any --gid/int --client/int -> any:
    return ping arguments
  ping value/int -> int:
    return value + 1

SELECTORS ::= {"X": PingService.X, "Y": PingService.Y, "Z": PingService.Z}

main args:
  if args is Map:
    role := args["role"]
    if role == "provider":
      (PingProvider SELECTORS[args["service"]]).install
      while true: sleep --ms=100
    run-sandbox args
    return
  run-driver

/**
A sandbox: expects to open the services in "may" and not to find the ones
  in "may-not".
*/
run-sandbox args/Map -> none:
  timeout := Duration --ms=(args.get "timeout-ms" --if-absent=: 100)
  (args.get "may" --if-absent=: []).do: | name/string |
    client := PingClient SELECTORS[name]
    client.open --timeout=timeout
    if (client.ping 41) != 42: exit 1
    client.close
  (args.get "may-not" --if-absent=: []).do: | name/string |
    exception := catch: (PingClient SELECTORS[name]).open --timeout=timeout
    if exception != "Cannot find service":
      print "$name: $exception"
      exit 2
  // Printing goes through a service that is always available.
  print "sandbox $args["role"] done"
  bypass := args.get "bypass"
  if bypass:
    exception := catch: open-without-discovery bypass[0] bypass[1] PingService.X
    if exception != "PERMISSION_DENIED":
      print "bypass: $exception"
      exit 3
  exit 0

run-sandbox-container arguments/Map --services/any -> int:
  container := containers.start containers.current arguments
      --untrusted
      --services=services
  return container.wait

run-driver -> none:
  x := containers.start containers.current {"role": "provider", "service": "X"}
  y := containers.start containers.current {"role": "provider", "service": "Y"}
  (PingClient PingService.X).open --timeout=(Duration --s=5)
  (PingClient PingService.Y).open --timeout=(Duration --s=5)

  // Two sandboxes with different lists.
  expect-equals 0
      run-sandbox-container {"role": "a", "may": ["X"], "may-not": ["Y"]}
          --services=[PingService.X.uuid]
  expect-equals 0
      run-sandbox-container {"role": "b", "may": ["Y"], "may-not": ["X"]}
          --services=[PingService.Y]  // A selector works as well.
  expect-equals 0
      run-sandbox-container {"role": "both", "may": ["X", "Y"]}
          --services=[PingService.Y.uuid, PingService.X.uuid]
  // "all": every provider that accepts sandboxed clients.
  expect-equals 0
      run-sandbox-container {"role": "every", "may": ["X", "Y"]}
          --services="all"
  // No list (the default): no service but discovery and printing.
  expect-equals 0
      run-sandbox-container {"role": "none", "may-not": ["X", "Y"]}
          --services=null

  // Sending to X's pid without discovery is refused by the VM, whatever
  // the sandbox's library does.
  ids := provider-ids PingService.X.uuid
  expect-equals 0
      run-sandbox-container {"role": "bypass", "may": ["Y"], "may-not": ["X"], "bypass": ids}
          --services=[PingService.Y.uuid]

  // Waiting discoveries: Z starts while both sandboxes wait for it; only
  // the one that may use it gets it.
  late := containers.start containers.current
      {"role": "late", "may": ["Z"], "timeout-ms": 10_000}
      --untrusted
      --services=[PingService.Z.uuid]
  late-denied := containers.start containers.current
      {"role": "late-denied", "may-not": ["Z"], "timeout-ms": 2_000}
      --untrusted
      --services=[PingService.X.uuid]
  sleep --ms=500
  z := containers.start containers.current {"role": "provider", "service": "Z"}
  expect-equals 0 late.wait
  expect-equals 0 late-denied.wait

  // Malformed lists are refused before the container starts.
  too-many := List 17: "6a0f1c2e-41d3-4b8a-9e57-0c1d2e3f4b$(%02d it)"
  expect-equals "INVALID_ARGUMENT"
      catch: run-sandbox-container {"role": "never"} --services=too-many
  expect-equals "WRONG_OBJECT_TYPE"
      catch: run-sandbox-container {"role": "never"} --services=[42]
  expect-equals "INVALID_ARGUMENT"
      catch: run-sandbox-container {"role": "never"} --services=[""]
  expect-equals "INVALID_ARGUMENT"
      catch: run-sandbox-container {"role": "never"} --services=["x" * 65]
  expect-equals "WRONG_OBJECT_TYPE"
      catch: run-sandbox-container {"role": "never"} --services="some"

  x.stop
  y.stop
  z.stop
  print "OK"
