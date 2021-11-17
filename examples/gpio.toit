// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import gpio

// The ESP DevKit V1 has an LED connected to pin 2.
LED ::= 2

main:
  pin := gpio.Pin.out LED
  pin.set 1
  sleep --ms=2000
  pin.set 0
