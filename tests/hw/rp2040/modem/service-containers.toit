// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.containers
import system.storage
import uart
import uuid
import .service-provider show STATE

image name/string -> uuid.Uuid:
  matches := containers.images.filter: it.name == name
  expect-equals 1 matches.size
  return matches.first.id

main:
  state := storage.Bucket.open --ram STATE
  provider/containers.Container? := null
  try:
    provider = containers.start (image "net-provider")
    with-timeout --ms=10_000:
      while not (state.get "ready"): sleep --ms=10
    // Repeat with the same provider to exercise heap-page reuse after exits.
    3.repeat:
      ["shared", "abandon", "hold", "shared"].do: | mode/string |
        if mode == "hold": state["holding"] = false
        before := state.get "closes" --init=(: 0)
        child := containers.start (image "net-client") [mode]
        try:
          with-timeout --ms=60_000:
            if mode == "hold":
              while not (state.get "holding"): sleep --ms=10
              child.stop
            else:
              expect-equals 0 child.wait
            while (state.get "closes" --init=(: 0)) != before + 1: sleep --ms=10
          expect-equals (before + 1) (state.get "opens")
          (uart.Port --tx=0 --rx=1 --baud-rate=115_200).close
          print "RP2040 ESP8285 container cleanup $mode: PASS"
        finally:
          child.close
    provider.stop
    (uart.Port --tx=0 --rx=1 --baud-rate=115_200).close
    print "RP2040 ESP8285 separate containers: PASS"
  finally:
    if provider:
      catch: provider.stop
      provider.close
    state.close
