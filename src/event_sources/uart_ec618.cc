// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "../top.h"

#ifdef TOIT_EC618

#include "uart_ec618.h"

namespace toit {

Ec618EventSource* Ec618EventSource::instance_ = null;

Ec618EventSource::Ec618EventSource()
    : EventSource("Ec618", 1)
    , Thread("Ec618Event")
    , queue_(xQueueCreate(32, sizeof(Event)))
    , pending_uart_errors_(0)
    , stop_(false) {
  ASSERT(instance_ == null);
  instance_ = this;
  spawn(4 * KB);
}

Ec618EventSource::~Ec618EventSource() {
  stop_ = true;
  Event stop_event = { Event::STOP, 0 };
  xQueueSend(queue_, &stop_event, portMAX_DELAY);
  join();
  vQueueDelete(queue_);
  instance_ = null;
}

void Ec618EventSource::on_unregister_resource(Locker& locker, Resource* r) {
  // Nothing special needed.
}

bool Ec618EventSource::claim_uart_error(Event::Type type,
                                        word data,
                                        uint32_t* pending_bit) {
  *pending_bit = 0;
  if (data != Event::UART_KIND_ERROR ||
      type < Event::UART_0 || type > Event::UART_2) {
    return true;
  }
  *pending_bit = 1u << (type - Event::UART_0);
  return !(__atomic_fetch_or(&pending_uart_errors_, *pending_bit,
                             __ATOMIC_RELAXED) & *pending_bit);
}

void Ec618EventSource::release_uart_error(uint32_t pending_bit) {
  if (pending_bit == 0) return;
  __atomic_fetch_and(&pending_uart_errors_, ~pending_bit, __ATOMIC_RELAXED);
}

void Ec618EventSource::send_event(Event::Type type, word data) {
  if (instance_ == null) return;
  uint32_t pending_bit;
  if (!instance_->claim_uart_error(type, data, &pending_bit)) return;
  Event event = { type, data };
  if (xQueueSend(instance_->queue_, &event, 0) != pdTRUE) {
    instance_->release_uart_error(pending_bit);
  }
}

void Ec618EventSource::send_event_from_isr(Event::Type type, word data) {
  if (instance_ == null) return;
  uint32_t pending_bit;
  if (!instance_->claim_uart_error(type, data, &pending_bit)) return;
  Event event = { type, data };
  BaseType_t xHigherPriorityTaskWoken = pdFALSE;
  if (xQueueSendFromISR(instance_->queue_, &event,
                        &xHigherPriorityTaskWoken) != pdTRUE) {
    instance_->release_uart_error(pending_bit);
  }
  portYIELD_FROM_ISR(xHigherPriorityTaskWoken);
}

void Ec618EventSource::entry() {
  while (!stop_) {
    Event event;
    if (xQueueReceive(queue_, &event, portMAX_DELAY) != pdTRUE) continue;
    if (event.type == Event::STOP) break;

    Locker locker(mutex());
    // Dispatch to all resources with matching event type.
    // EventResource stores the event type for matching.
    for (auto r : resources()) {
      auto er = static_cast<EventResource*>(r);
      if (er->event_type() == event.type) {
        dispatch(locker, r, event.data);
      }
    }
    if (event.data == Event::UART_KIND_ERROR &&
        event.type >= Event::UART_0 && event.type <= Event::UART_2) {
      uint32_t pending_bit = 1u << (event.type - Event::UART_0);
      release_uart_error(pending_bit);
    }
  }
}

}  // namespace toit

#endif  // TOIT_EC618
