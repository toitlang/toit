// Copyright (C) 2026 Toit contributors.

// Host reproduction of the soak's stuck workers (s3-ota-soak, s3b): RPC
// clients that run out of memory. The driver (trusted) provides the soak
// service and starts WORKERS worker containers from its own image with a
// small heap quota (untrusted on format 2, or trusted with
// set-max-heap-size_ when UNTRUSTED is false). Each worker runs the soak
// worker loop (RPC echo + add, churn, three tasks joined by a latch, a
// sleep) and also grows a ballast list until an allocation fails, so it
// runs out of memory at many different points of the loop. A watchdog
// task in each worker prints, every second, the iteration, the phase of
// the main task and the RPC ids it waits for; the driver reports workers
// whose iteration count stopped.
//
// Usage: toit run stuck.toit [workers] [heap-bytes] [untrusted:0/1] [seconds]

import monitor
import system.containers
import system.services
import system
import rpc

MARK ::= 0
interface StuckService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="7a2c4e60-1b3d-4f5a-9e8d-0c1b2a3d4e5f"
      --major=1
      --minor=0
  echo value/any -> any
  static ECHO-INDEX ::= 0
  add a/int b/int -> int
  static ADD-INDEX ::= 1
  report stats/List -> none
  static REPORT-INDEX ::= 2

class StuckClient extends services.ServiceClient implements StuckService:
  static SELECTOR ::= StuckService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    super selector
  echo value/any -> any: return invoke_ StuckService.ECHO-INDEX value
  add a/int b/int -> int: return invoke_ StuckService.ADD-INDEX [a, b]
  report stats/List -> none: invoke_ StuckService.REPORT-INDEX stats

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  calls := 0
  reports := {:}
  constructor:
    super "stuck" --major=1 --minor=0
    provides StuckService.SELECTOR --handler=this
  accepts-untrusted-clients -> bool: return true
  handle index/int arguments/any --gid/int --client/int -> any:
    calls++
    if index == StuckService.ECHO-INDEX: return arguments
    if index == StuckService.ADD-INDEX: return arguments[0] + arguments[1]
    if index == StuckService.REPORT-INDEX:
      reports[arguments[0]] = arguments
      return null
    unreachable

phase := "start"
iter := 0
oom := 0
errors := 0
last-error := ""
watchdog-errors := 0

run-worker k/int heap/int untrusted/bool -> none:
  if not untrusted: set-max-heap-size_ heap
  client := StuckClient
  client.open
  task --background::
    while true:
      e := catch:
        sleep --ms=1000
        print "W$k iter=$iter phase=$phase oom=$oom errors=$errors processing=$is-processing-messages_ pending=$(rpc.Rpc.instance.synchronizer_.map_.size) wd-errors=$watchdog-errors drops=$handler-drops_ rpc-phase=$rpc.rpc-phase_ drop=$handler-last-drop-type_:$handler-last-drop_ last=$last-error"
      if e: watchdog-errors++
  ring := List 8
  ballast := []
  while true:
    iter++
    exception := catch:
      phase = "echo"
      payload := ByteArray 512 + (iter * 37) % 512: (it + iter) & 0xff
      echoed := client.echo payload
      if echoed.size != payload.size: errors++
      phase = "add"
      if (client.add iter k) != iter + k: errors++
      phase = "churn"
      m := {:}
      8.repeat: m["k$it"] = "v$it-$iter"
      ring[iter % 8] = [m, List 32: it * iter, ByteArray 256, "s$iter " * 4]
      phase = "ballast"
      ballast.add (ByteArray 700)
      phase = "tasks"
      latch := monitor.Latch
      count := 0
      3.repeat: | t |
        task::
          sum := 0
          (200 + t * 50).repeat: sum += it
          count++
          if count == 3: latch.set sum
      latch.get
      phase = "sleep"
      sleep --ms=(iter % 7) * 3
    if exception:
      errors++
      last-error = "$phase:$exception"
      if exception == "OUT_OF_MEMORY" or exception == "ALLOCATION_FAILED" or exception == "MALLOC_FAILED":
        oom++
        ballast = ballast[ballast.size / 2..].copy
    if iter % 40 == 0:
      phase = "report"
      pid := -1
      catch: pid = Process.current.id
      catch: client.report [k, iter, oom, errors, pid]

main args:
  if args is Map:
    run-worker args["k"] args["heap"] args["untrusted"]
    return
  workers := args.size > 0 ? int.parse args[0] : 3
  heap := args.size > 1 ? int.parse args[1] : 100_000
  untrusted := args.size > 2 ? args[2] == "1" : true
  seconds := args.size > 3 ? int.parse args[3] : 30
  provider := Provider
  provider.install
  gids := {:}
  workers.repeat: | k |
    arguments := {"k": k, "heap": heap, "untrusted": untrusted}
    on-stopped := :: | code | print "D worker $k stopped: $code"
    container := untrusted
        ? containers.start containers.current arguments --untrusted --quotas={"heap": heap} --on-stopped=on-stopped
        : containers.start containers.current arguments --on-stopped=on-stopped
    gids[k] = container.gid
  last := {:}
  stuck := {:}
  (seconds / 5).repeat:
    sleep --ms=5_000
    line := "D calls=$provider.calls"
    workers.repeat: | k |
      r := provider.reports.get k
      line += " w$k=$(r ? r[1..] : "-")"
      if r:
        // GC count, allocated, reserved, mailbox messages, bytes allocated.
        s := system.process-stats gids[k] r[4]
        if s: line += "[gc=$s[0] alloc=$s[1] res=$s[2] msgs=$s[3] total=$s[4]]"
      if r and (last.get k) == r[1]:
        stuck[k] = (stuck.get k --if-absent=: 0) + 1
      else:
        stuck[k] = 0
      last[k] = r ? r[1] : null
    print line
  stuck-workers := (stuck.filter: | _ v | v >= 2).keys
  print "RESULT stuck=$stuck-workers calls=$provider.calls"
  exit (stuck-workers.is-empty ? 0 : 2)
