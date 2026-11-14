// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .hw.ec618.uart2-esp32 show check-lines
import .hw.ec618.uart1-idle-rx-ec618 show check-idle-rx
import .hw.ec618.uart2-config-ec618 as config
import .hw.ec618.uart2-rs485-esp32 as rs485

class FakePort:
  script/List
  index := 0
  pending := false

  constructor .script:

  in -> FakePort: return this

  read -> ByteArray?:
    if index < script.size:
      value := script[index++]
      if value is ByteArray or value == null: return value
      throw value
    pending = true
    try:
      sleep --ms=10_000
      unreachable
    finally:
      pending = false

main:
  // Check real parsing across read boundaries, ignoring an unrelated line.
  check-lines (FakePort [
    "unrelated\nEC618-UA".to-byte-array,
    "RT2 115200 0\nEC618-UART2 115200 1\nEC618-UART2 115200 2\n".to-byte-array,
    "EC618-UART2 115200 3\nEC618-UART2 115200 4\n".to-byte-array,
  ]) 115200 --timeout=(Duration --ms=100)

  error := catch: check-lines (FakePort []) 115200 --timeout=(Duration --ms=1)
  expect (error is string and error.contains "FAIL baud=115200 only 0/5")
  expect-throw "uart closed": check-lines (FakePort [null]) 115200

  marker := Object
  ["CLOSED", "HARDWARE_ERROR", "INVALID_ARGUMENT", marker].do: |failure|
    error = catch: check-lines (FakePort [failure]) 115200
    expect-identical failure error
    error = catch: config.read-exactly (FakePort [failure]) 2
    expect-identical failure error
    error = catch: rs485.read-exactly (FakePort [failure]) 2 100
    expect-identical failure error
    // A failed worker must wake the caller immediately, without waiting for
    // the default 30-second phase or being mistaken for idle input.
    error = catch:
      with-timeout --ms=100: check-idle-rx (FakePort [failure])
    expect-identical failure error
  expect-throw "uart1-idle-rx: FAIL reader closed during observation":
    with-timeout --ms=100: check-idle-rx (FakePort [null])

  // Successful completion must cancel the still-blocked reader.
  port := FakePort [#[1]]
  check-idle-rx port --phases=1 --phase=(Duration --ms=10)
  expect (not port.pending)
  // A middle phase with no progress fails immediately, even after good RX.
  port = FakePort [#[1]]
  expect-throw "uart1-idle-rx: FAIL no RX progress in phase 1":
    check-idle-rx port --phases=5 --phase=(Duration --ms=10)
  expect (not port.pending)
  expect-equals #[1, 2, 3] (config.read-exactly (FakePort [#[1], #[2, 3]]) 3)
  // Intentional parity-error tests allow a short read only after a deadline.
  expect-equals #[1] (config.read-exactly (FakePort [#[1]]) 2 --stall-ms=1)
  expect-throw "UART2 config reader closed":
    config.read-exactly (FakePort [#[1], null]) 2
  expect-equals #[1, 2, 3] (rs485.read-exactly (FakePort [#[1], #[2, 3]]) 3 100)
  expect-equals #[1] (rs485.read-exactly (FakePort [#[1]]) 2 1)
  expect-throw "UART2 RS485 reader closed":
    rs485.read-exactly (FakePort [#[1], null]) 2 100
  print "UART observers: parsing, deadlines, EOF, driver errors and worker cleanup PASS"
