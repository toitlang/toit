// Copyright (C) 2026 Toit contributors.

// Host timing of service calls between two processes (spawn), for
// comparing format 1 and format 2 on the same VM.

import .echo-service

main:
  spawn::
    provider := EchoServiceProvider
    provider.install
  sleep --ms=100
  client := EchoServiceClient
  client.open --timeout=(Duration --s=10)
  5.repeat:
    start := Time.monotonic-us
    s := 0
    2000.repeat: s = client.add s it
    print "RPC 2000 $(Time.monotonic-us - start) us"
  client.close
