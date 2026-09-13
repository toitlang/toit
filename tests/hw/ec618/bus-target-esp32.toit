// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .bus-control-esp32 as bridge
import .bus-target-s3 as fixture
import .wiring as wiring

/**
Serves the I2C0 register target on the classic ESP32 and forwards UART1 control.

Install as a standalone boot container with Wi-Fi credentials. Its serial
  console is the coordinator's target endpoint. SPI remains disabled because
  the SPI fixture pins belong to the separate S3.
*/
main:
  forwarding := task:: bridge.main
  try:
    fixture.serve --sda=wiring.ESP32-I2C0-SDA-PIN --scl=wiring.ESP32-I2C0-SCL-PIN
  finally:
    forwarding.cancel
