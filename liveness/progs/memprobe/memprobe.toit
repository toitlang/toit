// Copyright (C) 2026 Toit contributors.

// Where the heap of a worker container goes (esp32-final, memory question
// 1). A trusted boot container that provides the soak service and, for
// each worker kind of its assets (images named <kind>), starts one, two
// and three workers of that kind, one after the other; WAIT-S seconds
// after each start (and after stopping them all again) it prints:
//   MP <kind> n=<n> free=<system free> largest=<largest free block>
//   MPW <kind> n=<n> w<k> iters=<i> gc=<minor>,<full> alloc=<live bytes>
//       reserved=<heap bytes> total=<bytes allocated since start>
//   a heap report (system.serial-print-heap-report): bytes per malloc tag
//       and the Toit heap pages of each process.
// The workers are the soak worker (soak-worker.toit: RPC, churn, tasks)
// and an idle one (idle.toit: opens the service and sleeps), each
// untrusted format 2 (u-), trusted format 2 (t2-) or trusted format 1
// (t1-); a firmware runs the kinds its assets hold.

import monitor
import system
import system.assets
import system.containers
import system.services
import .soak-service

MARK ::= 0x6d00
WAIT-S ::= 45

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  calls := 0
  reports := {:}

  constructor:
    super "soak" --major=1 --minor=0
    provides SoakService.SELECTOR --handler=this

  accepts-untrusted-clients -> bool: return true

  handle index/int arguments/any --gid/int --client/int -> any:
    calls++
    if index == SoakService.ECHO-INDEX: return arguments
    if index == SoakService.ADD-INDEX: return arguments[0] + arguments[1]
    if index == SoakService.REPORT-INDEX:
      reports[arguments[0]] = arguments
      return null
    unreachable

install name/string image/ByteArray index/int -> any:
  writer := containers.ContainerImageWriter image.size
  try:
    List.chunk-up 0 image.size 4096: | from to | writer.write image[from..to]
    return writer.commit --data=(MARK + index) --untrusted=(name.starts-with "u-")
  finally:
    writer.close

report provider/Provider kind/string n/int workers/List -> none:
  // Let the system settle a little and collect garbage in this process.
  stats := system.process-stats --gc
  print "MP $kind n=$n free=$stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest=$stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE] ctl-alloc=$stats[system.STATS-INDEX-ALLOCATED-MEMORY] ctl-reserved=$stats[system.STATS-INDEX-RESERVED-MEMORY] calls=$provider.calls"
  workers.size.repeat: | k |
    container/containers.Container := workers[k]
    r := provider.reports.get k
    if r:
      ws := system.process-stats container.gid r[2]
      if ws:
        print "MPW $kind n=$n w$k iters=$r[1] errors=$r[3] gc=$ws[system.STATS-INDEX-GC-COUNT],$ws[system.STATS-INDEX-FULL-GC-COUNT] alloc=$ws[system.STATS-INDEX-ALLOCATED-MEMORY] reserved=$ws[system.STATS-INDEX-RESERVED-MEMORY] total=$ws[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP]"
      else:
        print "MPW $kind n=$n w$k gone"
    else:
      print "MPW $kind n=$n w$k no report"
  system.serial-print-heap-report "$kind n=$n"

main:
  provider := Provider
  provider.install
  containers.images.do: | image/containers.ContainerImage |
    if image.data & 0xff00 == MARK: catch: containers.uninstall image.id
  decoded := assets.decode
  kinds := decoded.keys.sort
  print "MP start: kinds $kinds"
  sleep --ms=5_000
  report provider "none" 0 []
  index := 0
  kinds.do: | kind/string |
    index++
    id := install kind decoded[kind] index
    workers := []
    provider.reports.clear
    3.repeat: | k |
      workers.add (containers.start id [k])
      sleep --ms=WAIT-S * 1000
      report provider kind (k + 1) workers
    workers.do: | container/containers.Container | catch: container.stop
    sleep --ms=10_000
    report provider kind 0 []
    catch: containers.uninstall id
  print "MP done"
  print "SUITE done"
