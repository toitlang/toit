// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
import expect show *
import host.file
import .records show fields number

main args:
  expect (4 <= args.size <= 5)
  seconds := args.size == 5 ? (int.parse args[4]) : 10
  expect (10 <= seconds <= 120)
  duration := args[3]
  expect (["default", "100"].contains duration)
  duration-label := duration == "default" ? "" : " buffer_ms=$duration"
  rate := int.parse args[0]
  bits := int.parse args[1]
  contents := (file.read-contents args[2]).to-string
  expect (not contents.contains "assert failed")
  expect (not contents.contains "Rebooting...")
  streams := []
  contents.split "\n": |line/string|
    prefix := "SPI console: STREAM "
    if line.starts-with prefix:
      streams.add (fields (line[prefix.size..].split " ") 0)
  expect-equals 1 streams.size
  stream/Map := streams[0]
  expect-equals 0 (number stream "stall_ms")
  target := ((rate * 2 * (bits / 8) * 2 + 4091) / 4092) * 4092
  expect-equals target (number stream "target")
  expect-equals target (number stream "bytes")
  expect-equals (target / 4092) (number stream "blocks")
  expect-equals (target * 8) (number stream "checked")
  expect-equals 0 (number stream "error")
  expect-equals 0 (number stream "errors")
  expect-equals 1 (number stream "counters")
  expect (0 <= (number stream "phase") < 251 * bits * 2)
  expect (1_900_000 <= (number stream "duration_us") < 3_000_000)
  first := number stream "start_before"
  last := number stream "end_after"
  expect (first <= (number stream "start_after") < (number stream "end_before") <= last)
  expect (target * 8 - 4 * bits <= last - first < (target + 6 * 4092) * 8)
  expect (contents.contains "I2S DUPLEX PASS master=true rate=$rate bits=$bits format=0 slots=0$duration-label capture_s=$seconds errors=0")
  print "Continuous SPI and reverse EC618 payload PASS rate=$rate bits=$bits bytes=$target"
