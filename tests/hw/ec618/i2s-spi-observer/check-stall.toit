// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
import expect show *
import host.file
import .records show fields number

main args:
  expect (args.size == 1 or args.size == 2)
  duration := args.size == 2 ? args[1] : "default"
  expect (["default", "100"].contains duration)
  duration-label := duration == "default" ? "" : " buffer_ms=$duration"
  contents := (file.read-contents args[0]).to-string
  streams := []
  wires := []
  contents.split "\n": |line/string|
    prefix := "SPI console: "
    if not line.starts-with prefix: continue.split
    parts := line[prefix.size..].split " "
    if parts[0] == "STREAM": streams.add (fields parts 1)
    if parts[0] == "WIRE" and parts[1].starts-with "windows=":
      wires.add (fields parts 1)
  expect-equals 1 streams.size
  expect-equals 1 wires.size
  stream/Map := streams[0]
  expect-equals 100 (number stream "stall_ms")
  expect-equals (-2) (number stream "error")
  expect-equals 4092 (number stream "bytes")
  expect-equals 1 (number stream "blocks")
  expect-equals 1_153_944 (number stream "target")
  expect-equals 0 (number stream "counters")
  expect-equals 1 (number wires[0] "invalid")
  expect (100_000 <= (number stream "duration_us") < 500_000)
  expect (contents.contains "I2S DUPLEX PASS master=true rate=96000 bits=24 format=0 slots=0$duration-label capture_s=10 errors=0")
  expect (contents.contains "SPI console: DUAL-REPLY OK")
  expect (not contents.contains "assert failed")
  expect (not contents.contains "Rebooting...")
  print "Deliberate 100-ms SPI consumer stall rejected by ring-pressure guard; reverse EC618 payload passed"
