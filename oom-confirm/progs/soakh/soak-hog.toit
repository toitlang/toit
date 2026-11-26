// Copyright (C) 2026 Toit contributors.

// oom-confirm: a sandboxed container that allocates until it is refused
// (its heap quota or the sandbox heap floor), for the over-capacity run.
// Each cycle: allocate 1 KB byte arrays and 64-element lists in turn until
// an allocation throws OUT_OF_MEMORY, drop the last 8 KB, report the cycle,
// the number of refusals and the KB held to the soak service (as worker
// 100), hold the memory for 20 s, drop everything and wait 10 s.

import .soak-service

HOG-ID ::= 100

main args:
  client := SoakServiceClient
  client.open
  cycles := 0
  refusals := 0
  others := 0
  while true:
    cycles++
    held := []
    kb := 0
    exception := catch:
      while true:
        held.add (ByteArray 1024)
        held.add (List 64)
        kb++
    if exception == "OUT_OF_MEMORY":
      refusals++
    else:
      others++
    16.repeat: if held.size > 0: held.remove-last
    pid := -1
    catch: pid = Process.current.id
    catch: client.report [HOG-ID, cycles, pid, refusals, kb, others]
    sleep --ms=20_000
    held = []
    sleep --ms=10_000
