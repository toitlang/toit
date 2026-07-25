// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .wiring as wiring

class OwnedPort:
  port/uart.Port
  tx/gpio.Pin
  rx/gpio.Pin

  constructor tx-number/int rx-number/int baud/int:
    tx = gpio.Pin tx-number
    rx = gpio.Pin rx-number
    port = uart.Port --tx=tx --rx=rx --baud-rate=baud

  close -> none:
    port.close
    rx.close
    tx.close

ec618-uart id/int baud/int -> OwnedPort:
  if id == 1:
    return OwnedPort
        wiring.EC618-UART1-TX-PAD
        wiring.EC618-UART1-RX-PAD
        baud
  if id == 2:
    return OwnedPort
        wiring.EC618-UART2-TX-PAD
        wiring.EC618-UART2-RX-PAD
        baud
  throw "unsupported EC618 rig UART$id"

esp32-uart id/int baud/int -> OwnedPort:
  if id == 1:
    return OwnedPort
        wiring.ESP32-UART1-TX-PIN
        wiring.ESP32-UART1-RX-PIN
        baud
  if id == 2:
    return OwnedPort
        wiring.ESP32-UART2-TX-PIN
        wiring.ESP32-UART2-RX-PIN
        baud
  throw "unsupported ESP32 rig UART$id"
