// Copyright (C) 2026 Toit contributors.

// Container start churn: for each image of its assets (u-*: installed
// untrusted, else trusted) starts it ROUNDS times one after the other and
// prints the system's free memory every 50 starts, to measure what one
// start-and-exit costs when it is not given back.
// The images (scripts/make-churn-images.sh): *-exit returns at once,
// *-throw dies with an uncaught exception, *-nosvc fails to open a service
// that does not exist (the soak worker's failure).

import system
import system.assets
import system.containers

ROUNDS ::= 300

free -> string:
  stats := system.process-stats
  return "free $stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest $stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]"

main:
  decoded := assets.decode
  decoded.keys.sort.do: | name/string |
    image/ByteArray := decoded[name]
    writer := containers.ContainerImageWriter image.size
    id := null
    try:
      List.chunk-up 0 image.size 4096: | from to | writer.write image[from..to]
      id = writer.commit --untrusted=(name.starts-with "u-")
    finally:
      writer.close
    sleep --ms=500
    print "CHURN $name start 0 $free"
    codes := {:}
    ROUNDS.repeat: | i |
      code := -1
      exception := catch: code = (containers.start id).wait
      key := exception ? "$exception" : "$code"
      codes[key] = (codes.get key --if-absent=: 0) + 1
      if (i + 1) % 50 == 0:
        sleep --ms=200
        print "CHURN $name start $(i + 1) $free"
    containers.uninstall id
    sleep --ms=500
    print "CHURN $name done $free codes $codes"
  print "SUITE done"
