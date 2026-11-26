// Copyright (C) 2026 Toit contributors.

// measure-3: driver calls that ESP-IDF rejects through its ESP_RETURN_ON_*
// checks (the ones TOIT_SILENT_IDF_CHECKS makes silent). Prints the Toit
// exception of each, so the f1, f2 and f2-without-the-option builds can be
// compared.

import i2c
import uart
import system

try-case name/string [block]:
  e := catch: block.call
  print "DRV $name: $(e == null ? "no exception" : e)"

main:
  // uart_param_config: "baud rate unachievable" (ESP_FAIL).
  try-case "uart-create-baud-1":
    port := uart.Port --rx=4 --baud-rate=1
    port.close
  // uart_set_baudrate on an open port: "baud rate unachievable" (ESP_FAIL).
  try-case "uart-set-baud-1":
    port := uart.Port --rx=4 --baud-rate=115200
    try:
      port.baud-rate = 1
    finally:
      port.close
  if system.architecture == system.ARCHITECTURE-ESP32:
    // gpio_set_level of an input-only pad in the I2C driver's pin setup
    // (ESP_ERR_INVALID_ARG through two ESP_RETURN_ON_* levels).
    try-case "i2c-input-only-sda":
      bus := i2c.Bus --sda=34 --scl=33
      bus.close
  print "SUITE done"
