// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

#include "../top.h"

namespace toit {

// Event types for the shared EC618 event source.
// UART and GPIO events are dispatched through the same queue.
struct Event {
  // Computed GPIO/peripheral types extend beyond the named enum constants.
  // A fixed underlying type makes those values valid C++ enum values too.
  enum Type : uint32_t {
    STOP = 0,
    UART_0,
    UART_1,
    UART_2,
    GPIO_NUM_0,
    // GPIO_NUM_1 through GPIO_NUM_31 follow sequentially.
  };
  Type type;
  word data;

  // Sub-event encoded in `data` for UART_* events.
  enum UartKind {
    UART_KIND_RX = 0,
    UART_KIND_TX_DONE = 1,
    UART_KIND_ERROR = 2,
    UART_KIND_BREAK = 3,
  };

  static Type gpio_type(int pin) {
    return static_cast<Type>(GPIO_NUM_0 + pin);
  }

  static Type uart_type(int id) {
    return static_cast<Type>(UART_0 + id);
  }

  // I2C controller completion events (after the 32 GPIO slots).
  static Type i2c_type(int id) {
    return static_cast<Type>(GPIO_NUM_0 + 32 + id);
  }

  // A type no event is ever sent for. Used by resources that must exist
  // without an event stream (e.g. a Pin on a pad with no GPIO function,
  // held purely to carry the pad number into a peripheral).
  static Type none_type() {
    return static_cast<Type>(GPIO_NUM_0 + 34);
  }

  // SPI controller completion events (async transfers).
  static Type spi_type(int id) {
    return static_cast<Type>(GPIO_NUM_0 + 35 + id);
  }

  static Type one_wire_type() {
    return static_cast<Type>(GPIO_NUM_0 + 37);
  }

  static Type i2s_type(int id) {
    return static_cast<Type>(GPIO_NUM_0 + 38 + id);
  }

  static Type adc_type(int channel) {
    return static_cast<Type>(GPIO_NUM_0 + 40 + channel);
  }
};

}  // namespace toit
