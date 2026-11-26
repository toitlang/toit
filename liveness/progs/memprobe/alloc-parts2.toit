// Copyright (C) 2026 Toit contributors.

// Bytes allocated in the object heap per iteration of the parts of the
// soak worker's loop (esp32-final, memory question 1; memory-pressure: the
// provider stops when the client reports), for comparing
// format 1 and format 2 on one host: run with TOIT_BYTECODE_FORMAT=1 and
// =2. The RPC part calls a provider in a spawned process.

import monitor
import system
import .soak-service
import system.services

N ::= 400

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  constructor:
    super "soak" --major=1 --minor=0
    provides SoakService.SELECTOR --handler=this
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == SoakService.ECHO-INDEX: return arguments
    if index == SoakService.ADD-INDEX: return arguments[0] + arguments[1]
    if index == SoakService.REPORT-INDEX:
      task:: sleep --ms=50; exit 0
      return null
    return null

allocated -> int:
  return (system.process-stats)[system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP]

measure name/string [block] -> none:
  // Warm up (lazy statics, grown stacks).
  20.repeat: block.call it
  before := allocated
  N.repeat: block.call it + 20
  after := allocated
  print "PART $name $((after - before) / N) B/iteration"

main args:
  if not args.is-empty:
    provider := Provider
    provider.install
    sleep --ms=60_000
    return
  spawn:: main ["provider"]
  sleep --ms=500
  client := SoakServiceClient
  client.open
  ring := List 8
  measure "echo": | iter |
    payload := ByteArray 512 + (iter * 37) % 512: (it + iter) & 0xff
    client.echo payload
  measure "add": | iter |
    client.add iter 1
  measure "churn": | iter |
    m := {:}
    8.repeat: m["k$it"] = "v$it-$iter"
    l := List 32: it * iter
    ring[iter % 8] = [m, l, ByteArray 256 + (iter % 4) * 64, "s$iter " * 4]
  measure "tasks": | iter |
    latch := monitor.Latch
    count := 0
    3.repeat: | t |
      task::
        sum := 0
        (200 + t * 50).repeat: sum += it
        s := "$sum-$t"
        count++
        if count == 3: latch.set s
    latch.get
  measure "sleep": | iter |
    sleep --ms=(iter % 7) * 3
  measure "catch": | iter |
    catch: iter + 1
  measure "loop": | iter |
    exception := catch:
      payload := ByteArray 512 + (iter * 37) % 512: (it + iter) & 0xff
      client.echo payload
      client.add iter 1
      m := {:}
      8.repeat: m["k$it"] = "v$it-$iter"
      l := List 32: it * iter
      ring[iter % 8] = [m, l, ByteArray 256 + (iter % 4) * 64, "s$iter " * 4]
      latch := monitor.Latch
      count := 0
      3.repeat: | t |
        task::
          sum := 0
          (200 + t * 50).repeat: sum += it
          s := "$sum-$t"
          count++
          if count == 3: latch.set s
      latch.get
      sleep --ms=(iter % 7) * 3
  client.report []
  client.close
  exit 0
