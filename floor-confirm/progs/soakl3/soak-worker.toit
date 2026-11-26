// Copyright (C) 2026 Toit contributors.

// A worker container of the soak test (installed untrusted on format-2
// firmware, trusted on format 1). Loops forever: RPC to the controller's
// service (echo of 0.5-1 KB, add), allocation churn that promotes objects
// and then drops them (a ring of 8 entries of lists, maps, strings and
// byte arrays, about 8 KB live: young and old-space collections), three short tasks per
// iteration joined with a latch, and a short sleep (timers). Every 40
// iterations it reports its counters and its pid to the service (the
// controller reads its GC counts).
//
// floor-confirm: the errors are also counted by kind. QUOTA_EXCEEDED of a
// call is "fast" when it came within QUOTA-FAST-US of the call's start (the
// worker's own send was refused: process-send throws before the call
// waits) and "slow" otherwise (the error reply the VM queues for a reply
// the trusted controller could not deliver to this sandbox); the fastest
// successful call is reported too, to show whether the split is sound.
// OUT_OF_MEMORY errors are counted apart. The calls attempted are reported
// as well: the controller counts the requests it received from this
// worker's group, so attempts minus received is the number of requests
// that never arrived (the worker's sends refused).

import monitor
import .soak-service

RING ::= 8
QUOTA-FAST-US ::= 1500

quota-fast := 0
quota-slow := 0
oom := 0
attempts := 0
fastest-us := 1_000_000_000

call [block] -> any:
  attempts++
  start := Time.monotonic-us
  result := null
  exception := catch: result = block.call
  elapsed := Time.monotonic-us - start
  if exception:
    if exception == "QUOTA_EXCEEDED":
      if elapsed < QUOTA-FAST-US: quota-fast++
      else: quota-slow++
    throw exception
  if elapsed < fastest-us: fastest-us = elapsed
  return result

main args:
  k := args.size > 0 ? args[0] : 0
  client := SoakServiceClient
  client.open
  ring := List RING
  iter := 0
  errors := 0
  while true:
    iter++
    exception := catch:
      payload := ByteArray 512 + (iter * 37) % 512: (it + iter) & 0xff
      echoed := call: client.echo payload
      if echoed.size != payload.size or echoed[7] != payload[7]: errors++
      if (call: client.add iter k) != iter + k: errors++
      m := {:}
      8.repeat: m["k$it"] = "v$it-$iter"
      l := List 32: it * iter
      ring[iter % RING] = [m, l, ByteArray 256 + (iter % 4) * 64, "s$iter " * 4]
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
    if exception:
      errors++
      if exception == "OUT_OF_MEMORY": oom++
    if iter % 40 == 0:
      // Sandboxed processes may not read process-stats: the controller
      // reads this process' GC counts by its pid.
      pid := -1
      catch: pid = Process.current.id
      catch: call: client.report [k, iter, pid, errors, quota-fast, quota-slow, oom, fastest-us, attempts]
