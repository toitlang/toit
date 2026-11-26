// Copyright (C) 2026 Toit contributors.

// The idle worker of memprobe.toit: opens the soak service, reports its
// pid once and sleeps (the fixed cost of a container with an RPC client).

import .soak-service

main args:
  k := args.size > 0 ? args[0] : 0
  client := SoakServiceClient
  client.open
  pid := -1
  catch: pid = Process.current.id
  client.report [k, 0, pid, 0]
  while true: sleep --ms=10_000
