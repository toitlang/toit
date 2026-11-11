// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.api.print show PrintService PrintServiceClient
import system.api.service-discovery show ServiceDiscoveryService ServiceDiscoveryServiceClient
import .sandbox

/**
Malformed calls to the services the system process offers to sandboxes
  (service discovery and the sandbox print service) fail in the sandbox
  and leave the system process working.

The untrusted container calls every method with arguments of the wrong
  type and shape, invalid method indexes, deeply nested arguments and
  arguments at the message size cap. Every call must throw (an exception
  reply from the system process), and afterwards discovery and printing
  must still work.
*/

deep-list depth/int -> List:
  result := []
  depth.repeat: result = [result]
  return result

main args:
  sandbox-test args --error="DONE": | arguments/Map |
    discovery := ServiceDiscoveryServiceClient
    discovery.open
    printer := PrintServiceClient
    printer.open

    big := ByteArray 200_000
    junk := [
      null, 42, -1, 3.5, "string", #[1, 2], [], [1], [null, null], {:}, {"a": 1},
      [1, 2, 3, 4, 5, 6, 7, 8], deep-list 50, big, [big],
    ]
    indexes := [
      ServiceDiscoveryService.DISCOVER-INDEX,
      ServiceDiscoveryService.LISTEN-INDEX,
      ServiceDiscoveryService.UNLISTEN-INDEX,
      ServiceDiscoveryService.WATCH-INDEX,
      4, 99, -1, 1 << 40,
    ]
    succeeded := []
    indexes.do: | index |
      junk.do: | argument |
        // Unlisten of an unknown id and watch of a pid quietly succeed.
        exception := catch: discovery.invoke_ index argument
        if not exception and index != ServiceDiscoveryService.UNLISTEN-INDEX
            and index != ServiceDiscoveryService.WATCH-INDEX:
          succeeded.add [index, argument is ByteArray ? "bytes" : argument]
    [PrintService.PRINT-INDEX, 1, -1, 99].do: | index |
      junk.do: | argument |
        // Printing a string is fine.
        if index == PrintService.PRINT-INDEX and argument is string: continue.do
        exception := catch: printer.invoke_ index argument
        if not exception: succeeded.add [index, argument]
    if not succeeded.is-empty: throw "SUCCEEDED $succeeded"

    // A long print is truncated, not refused.
    printer.print ("é" * 3_000)
    // The services still work.
    if (discover-pid SiblingService.SELECTOR.uuid) != arguments["sibling-pid"]: throw "WRONG_PROVIDER"
    printer.print "still printing"
    printer.close
    discovery.close
    throw "DONE"
