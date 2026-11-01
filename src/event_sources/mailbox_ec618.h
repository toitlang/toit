// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

#include "event_ec618.h"
#include "i2s_mailbox_ec618.h"

namespace toit {

// Retains persistent peripheral notifications independently of the bounded
// shared queue. GPIO edge events still use the queue directly: their individual
// transitions cannot be replaced with a latest value or a set of ready bits.
class Ec618EventMailbox {
 public:
  static bool retains(Event::Type type) {
    return is_uart(type) ||
        (type >= Event::i2c_type(0) && type <= Event::adc_type(1) &&
         type != Event::none_type());
  }

  // Returns whether to attempt a queue wake-up. Failure to enqueue must NOT
  // clear the mailbox: draining any existing queue entry will dispatch it.
  bool publish(Event::Type type, word data) {
    if (is_uart(type)) {
      ASSERT(data >= Event::UART_KIND_RX && data <= Event::UART_KIND_BREAK);
      uint32_t bit = 1u << data;
      return uart_[type - Event::UART_0].fetch_or(bit, std::memory_order_acq_rel) == 0;
    }
    if (retains(type)) {
      return completions_.publish(type - Event::i2c_type(0), uint32_t(data));
    }
    return true;
  }

  template <typename Dispatch>
  void drain(Dispatch dispatch) {
    for (unsigned id = 0; id < 3; id++) {
      uint32_t kinds = uart_[id].exchange(0, std::memory_order_acq_rel);
      for (unsigned kind = Event::UART_KIND_RX; kind <= Event::UART_KIND_BREAK; kind++) {
        if (kinds & (1u << kind)) dispatch(Event::uart_type(id), kind);
      }
    }
    for (unsigned id = 0; id < kCompletionCount; id++) {
      uint32_t data;
      if (completions_.take(id, &data)) {
        dispatch(static_cast<Event::Type>(Event::i2c_type(0) + id), data);
      }
    }
  }

 private:
  static bool is_uart(Event::Type type) {
    return type >= Event::UART_0 && type <= Event::UART_2;
  }

  // I2C(2), unused none_type(1), SPI(2), 1-Wire(1), I2S(2), ADC(2).
  static const unsigned kCompletionCount = 10;
  std::atomic<uint32_t> uart_[3] = {};
  CompletionEventMailbox<kCompletionCount> completions_;
};

}  // namespace toit
