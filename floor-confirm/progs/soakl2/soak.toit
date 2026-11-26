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
WORKERS ::= 2
HOST ::= "192.168.77.248"
NET-PORT ::= 7998

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  calls := 0
  reports := {:}
  // floor-confirm: the requests received per client group.
  received := {:}

  constructor:
    super "soak" --major=1 --minor=0
    provides SoakService.SELECTOR --handler=this

  // Serving sandboxed clients is opt-in (docs/sandbox-policy.md).
  accepts-untrusted-clients -> bool: return true

  handle index/int arguments/any --gid/int --client/int -> any:
    calls++
    received[gid] = (received.get gid --if-absent=: 0) + 1
    if index == SoakService.ECHO-INDEX: return arguments
    if index == SoakService.ADD-INDEX: return arguments[0] + arguments[1]
    if index == SoakService.REPORT-INDEX:
      // floor-confirm: with the requests received from its group so far.
      n := received.get gid --if-absent=: 0
      reports[arguments[0]] = List arguments.size + 1: it < arguments.size ? arguments[it] : n
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

// floor-confirm: the outcomes of the memory floor are expected and counted:
// a start refused with QUOTA_EXCEEDED (the start floor or the restart delay
// after out-of-memory runs) is retried 5 s later and is not a restart; a
// worker stopped by the system to free memory exits with
// containers.EXIT-EVICTED (243) and is restarted like any other stop.
start-refused := 0
evicted := 0
installs-refused := 0
installs-evicted := 0
EXIT-EVICTED ::= 243

run-worker id k/int -> none:
  stopped-us := null
  refusals := 0
  while true:
    code := -1
    started := false
    exception := catch:
      container := containers.start id [k]
      started = true
      if stopped-us:
        print "SOAK-EVENT t=$(elapsed) worker $k restarted after $((Time.monotonic-us - stopped-us) / 1000) ms, $refusals refused starts"
      stopped-us = null
      refusals = 0
      worker-gids[k] = container.gid
      code = container.wait
    if not started and exception == "QUOTA_EXCEEDED":
      start-refused++
      refusals++
      if not stopped-us: stopped-us = Time.monotonic-us
      print "SOAK-EVENT t=$(elapsed) worker $k start refused: QUOTA_EXCEEDED"
      sleep --ms=5000
      continue
    if code == EXIT-EVICTED: evicted++
    restarts++
    key := exception ? "$exception" : "$code"
    exits[key] = (exits.get key --if-absent=: 0) + 1
    print "SOAK-EVENT t=$(elapsed) worker $k stopped: $key$(code == EXIT-EVICTED ? " (evicted)" : "")"
    stopped-us = Time.monotonic-us
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
    // [worker, iterations, pid, errors, quota-fast, quota-slow, oom,
    // fastest-call-us]; the worker process' GC counts (minor, full,
    // compacting) are read here by its group and pid.
    if r and worker-gids.contains k:
      ws := null
      catch: ws = system.process-stats worker-gids[k] r[2]
      gcs := ws ? "$ws[system.STATS-INDEX-GC-COUNT],$ws[system.STATS-INDEX-FULL-GC-COUNT],$ws[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]" : "gone"
      // floor-confirm: QUOTA_EXCEEDED of the worker's calls, split by
      // when it came (see soak-worker.toit), its OUT_OF_MEMORY errors and
      // its fastest successful call.
      q := r.size >= 10 ? ",q=$r[4]/$r[5],oom=$r[6],min-us=$r[7],sent=$r[8],recv=$r[9]" : ""
      workers += " w$k=$r[1],$r[3],$gcs$q"
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
  print "SOAK t=$(elapsed) free=$stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest=$stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE] ctl-gc=$stats[system.STATS-INDEX-GC-COUNT],$stats[system.STATS-INDEX-FULL-GC-COUNT],$stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] ctl-alloc=$stats[system.STATS-INDEX-ALLOCATED-MEMORY] calls=$provider.calls restarts=$restarts installs=$installs-ok/$installs-failed net=$net-ok/$net-failed refused=$start-refused evicted=$evicted ins-refused=$installs-refused ins-evicted=$installs-evicted$workers"

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
  started := false
  exception = catch:
    container := containers.start id
    started = true
    code = container.wait
  catch: containers.uninstall id
  // floor-confirm: a refused start (QUOTA_EXCEEDED) and an eviction (243)
  // of the installed program are counted apart from the failures.
  if not started and exception == "QUOTA_EXCEEDED":
    installs-refused++
    print "SOAK-EVENT t=$(elapsed) run $name: start refused: QUOTA_EXCEEDED"
  else if code == EXIT-EVICTED:
    installs-evicted++
    print "SOAK-EVENT t=$(elapsed) run $name: evicted (243)"
  else if exception or code != 0:
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
