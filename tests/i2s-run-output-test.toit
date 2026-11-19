// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .hw.shared.i2s-run-output

main:
  config := "master=true rate=16000 bits=16 format=0 slots=0"
  ready := "I2S RX READY $config\r\n"
  passed := "I2S RX PASS $config bytes=1024 overruns=0\n"
  (ready.size + 1).repeat: |split/int|
    parser := I2sRunOutput config
    starts := (parser.accept ready[..split]) ? 1 : 0
    if parser.accept ready[split..]: starts++
    expect-equals 1 starts
    expect parser.armed
    passed.size.repeat: parser.accept passed[it..it + 1]
    expect parser.passed
  parser := I2sRunOutput config
  expect (not (parser.accept "I2S RX READY master=false rate=16000 bits=16 format=0 slots=0\n"))
  expect (not parser.armed)
  expect (catch: parser.accept passed) != null
  parser.accept ready
  expect (catch: parser.accept ready) != null
  expect (catch: parser.accept "I2S RX PASS $config bytes=0 overruns=0\n") != null
  expect (catch: parser.accept "I2S RX PASS $config bytes=1024 overruns=1\n") != null
  ready = "I2S TX READY $config\n"
  passed = "I2S TX PASS $config errors=0\n"
  (ready.size + 1).repeat: |split/int|
    parser = I2sRunOutput config --transmit
    starts := (parser.accept ready[..split]) ? 1 : 0
    if parser.accept ready[split..]: starts++
    expect-equals 1 starts
    passed.size.repeat: parser.accept passed[it..it + 1]
    expect parser.passed
  parser = I2sRunOutput config --transmit
  expect (catch: parser.accept passed) != null
  parser.accept ready
  parser.accept "I2S RX PASS $config bytes=1024 overruns=0\n"
  expect (not parser.passed)
  ["1", "00", "0 ignored"].do:
    expect (catch: parser.accept "I2S TX PASS $config errors=$it\n") != null
  ready = "I2S DUPLEX READY $config\n"
  passed = "I2S DUPLEX PASS $config errors=0\n"
  (ready.size + 1).repeat: |split/int|
    parser = I2sRunOutput config --duplex
    starts := (parser.accept ready[..split]) ? 1 : 0
    if parser.accept ready[split..]: starts++
    expect-equals 1 starts
    passed.size.repeat: parser.accept passed[it..it + 1]
    expect parser.passed
  parser = I2sRunOutput config --duplex
  expect (catch: parser.accept passed) != null
  parser.accept ready
  parser.accept "I2S TX PASS $config errors=0\n"
  parser.accept "I2S RX PASS $config bytes=1024 overruns=0\n"
  expect (not parser.passed)
  ["1", "00", "0 ignored"].do:
    expect (catch: parser.accept "I2S DUPLEX PASS $config errors=$it\n") != null
  expect (catch: I2sRunOutput config --transmit --duplex) != null
  parser = I2sRunOutput "$config buffer_ms=100" --duplex
  expect (not (parser.accept ready))
  expect (not parser.armed)
  parser.accept "I2S DUPLEX READY $config buffer_ms=100\n"
  parser.accept passed
  expect (not parser.passed)
  parser.accept "I2S DUPLEX PASS $config buffer_ms=100 errors=0\n"
  expect parser.passed
  parser = I2sRunOutput "$config capture_s=10" --duplex
  expect (not (parser.accept "I2S DUPLEX READY $config capture_s=2\n"))
  expect (not parser.armed)
  parser.accept "I2S DUPLEX READY $config capture_s=10\n"
  parser.accept "I2S DUPLEX PASS $config capture_s=2 errors=0\n"
  expect (not parser.passed)
  parser.accept "I2S DUPLEX PASS $config capture_s=10 errors=0\n"
  expect parser.passed
