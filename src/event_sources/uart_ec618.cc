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

void Ec618EventSource::send_event(Event::Type type, word data) {
  if (instance_ == null) return;
  Event event = { type, data };
  xQueueSend(instance_->queue_, &event, 0);
}

void Ec618EventSource::send_event_from_isr(Event::Type type, word data) {
  if (instance_ == null) return;
  Event event = { type, data };
  BaseType_t xHigherPriorityTaskWoken = pdFALSE;
  xQueueSendFromISR(instance_->queue_, &event, &xHigherPriorityTaskWoken);
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
  }
}

}  // namespace toit

#endif  // TOIT_EC618
