// Copyright (C) 2026 Toit contributors.

// A worker container of the soak test (installed untrusted on format-2
// firmware, trusted on format 1). Loops forever: RPC to the controller's
// service (echo of 0.5-1 KB, add), allocation churn that promotes objects
// and then drops them (a ring of 8 entries of lists, maps, strings and
// byte arrays, about 8 KB live: young and old-space collections), three short tasks per
// iteration joined with a latch, and a short sleep (timers). Every 40
// iterations it reports its counters and its pid to the service (the
// controller reads its GC counts).

import monitor
import .soak-service

RING ::= 8

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
      echoed := client.echo payload
      if echoed.size != payload.size or echoed[7] != payload[7]: errors++
      if (client.add iter k) != iter + k: errors++
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
    if exception: errors++
    if iter % 40 == 0:
      // Sandboxed processes may not read process-stats: the controller
      // reads this process' GC counts by its pid.
      pid := -1
      catch: pid = Process.current.id
      catch: client.report [k, iter, pid, errors]
