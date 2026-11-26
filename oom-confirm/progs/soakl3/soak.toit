// Copyright (C) 2026 Toit contributors.

// The controller of the soak test (a trusted boot container). Provides the
// soak service, installs the worker image of its assets (u-worker:
// untrusted on format 2; t-worker: trusted on format 1) and keeps WORKERS
// workers running (restarting any that stops). Every 2 minutes it installs,
// runs and uninstalls one of the other images of its assets; every 5
// minutes (with WiFi) it opens the network, echoes 2 KB through the host
// (scripts/soak.sh runs the echo server on port 7998) and closes it again.
// Every minute it prints a SOAK line with the heap statistics, its own GC
// counts and the workers' last reports, and (liveness) a SOAKP line with
// every process's heap use and GC counts and a stall check per worker.

import io
import monitor
import net
import net.tcp
import system
import system.assets
import system.containers
import system.services
import .soak-service

MARK ::= 0x6b00
WORKERS ::= 3
HOST ::= "192.168.77.248"
NET-PORT ::= 7998

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  calls := 0
  reports := {:}

  constructor:
    super "soak" --major=1 --minor=0
    provides SoakService.SELECTOR --handler=this

  // Serving sandboxed clients is opt-in (docs/sandbox-policy.md).
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

restarts := 0
exits := {:}
installs-ok := 0
installs-failed := 0
net-ok := 0
net-failed := 0
start-us := Time.monotonic-us
worker-gids := {:}

run-worker id k/int -> none:
  while true:
    code := -1
    exception := catch:
      container := containers.start id [k]
      worker-gids[k] = container.gid
      code = container.wait
    restarts++
    key := exception ? "$exception" : "$code"
    exits[key] = (exits.get key --if-absent=: 0) + 1
    print "SOAK-EVENT t=$(elapsed) worker $k stopped: $key"
    sleep --ms=1000

elapsed -> int: return (Time.monotonic-us - start-us) / 1_000_000

last-iterations := {:}
stalls := 0

pstat-string s/List? -> string:
  if not s: return "gone"
  return "$s[system.STATS-INDEX-ALLOCATED-MEMORY],$s[system.STATS-INDEX-RESERVED-MEMORY],$s[system.STATS-INDEX-GC-COUNT],$s[system.STATS-INDEX-FULL-GC-COUNT],$s[system.STATS-INDEX-PROCESS-MESSAGE-COUNT]"

pstats gid/int pid/int -> string:
  s := null
  catch: s = system.process-stats gid pid
  return pstat-string s

report provider/Provider -> none:
  stats := system.process-stats
  workers := ""
  WORKERS.repeat: | k |
    r := provider.reports.get k
    // [worker, iterations, pid, errors]; the worker process' GC counts
    // (minor, full, compacting) are read here by its group and pid.
    if r and worker-gids.contains k:
      ws := system.process-stats worker-gids[k] r[2]
      gcs := ws ? "$ws[system.STATS-INDEX-GC-COUNT],$ws[system.STATS-INDEX-FULL-GC-COUNT],$ws[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]" : "gone"
      workers += " w$k=$r[1],$r[3],$gcs"
    else:
      workers += " w$k=-"
  // liveness: per-process heap use (allocated, reserved, GC counts,
  // mailbox) of the system process, the controller and the workers, and a
  // stall check (a worker whose iteration count did not move for a minute).
  procs := "sys=$(pstats 0 0) ctl=$(pstat-string stats)"
  WORKERS.repeat: | k |
    r := provider.reports.get k
    if r and worker-gids.contains k:
      procs += " w$k=$(pstats worker-gids[k] r[2])"
      last := last-iterations.get k
      if last == r[1]:
        stalls++
        print "SOAK-EVENT t=$(elapsed) worker $k stalled at $r[1]"
      last-iterations[k] = r[1]
  print "SOAKP t=$(elapsed) $procs stalls=$stalls"
  system.serial-print-heap-report "soak t=$(elapsed)"
  print "SOAK t=$(elapsed) free=$stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest=$stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE] ctl-gc=$stats[system.STATS-INDEX-GC-COUNT],$stats[system.STATS-INDEX-FULL-GC-COUNT],$stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] ctl-alloc=$stats[system.STATS-INDEX-ALLOCATED-MEMORY] calls=$provider.calls restarts=$restarts installs=$installs-ok/$installs-failed net=$net-ok/$net-failed$workers"

install-run-uninstall name/string image/ByteArray -> none:
  id := null
  system.serial-print-heap-report "before install $name"
  start := Time.monotonic-us
  exception := catch: id = install name image 0x50
  system.serial-print-heap-report "after commit $name"
  if not id:
    installs-failed++
    print "SOAK-EVENT t=$(elapsed) install $name failed: $exception"
    return
  code := -1
  exception = catch: code = (containers.start id).wait
  catch: containers.uninstall id
  if exception or code != 0:
    installs-failed++
    print "SOAK-EVENT t=$(elapsed) run $name: exit $code $exception"
  else:
    installs-ok++
  print "SOAK-INSTALL t=$(elapsed) $name $((Time.monotonic-us - start) / 1000) ms"
  system.serial-print-heap-report "after install $name"

network-round -> none:
  network := null
  socket := null
  system.serial-print-heap-report "before network"
  exception := catch:
    network = net.open
    socket = network.tcp-connect HOST NET-PORT
    data := ByteArray 2048: it & 0xff
    socket.out.write data
    received := socket.in.read-bytes data.size
    if received != data: throw "echo mismatch"
  if socket: catch: socket.close
  if network: catch: network.close
  if exception:
    net-failed++
    print "SOAK-EVENT t=$(elapsed) network: $exception"
  else:
    net-ok++
  system.serial-print-heap-report "after network"

main:
  provider := Provider
  provider.install
  containers.images.do: | image/containers.ContainerImage |
    if image.data & 0xff00 == MARK: catch: containers.uninstall image.id
  decoded := assets.decode
  names := decoded.keys.sort
  worker-name := (names.filter: it.ends-with "-worker")[0]
  others := names.filter: not it.ends-with "-worker"
  worker-id := install worker-name decoded[worker-name] 1
  print "SOAK start: worker image $worker-name ($worker-id), others $others"
  WORKERS.repeat: | k |
    task:: run-worker worker-id k
  tick := 0
  while true:
    sleep --ms=10_000
    tick++
    if tick % 6 == 0: report provider
    if tick % 12 == 3:
      name := others[(tick / 12) % others.size]
      install-run-uninstall name decoded[name]
    if tick % 30 == 9: network-round
