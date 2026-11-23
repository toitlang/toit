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
#include "task.h"

namespace toit {

static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "ISR publication requires lock-free pointers");
std::atomic<Ec618EventSource*> Ec618EventSource::instance_{null};

Ec618EventSource::Ec618EventSource()
    : EventSource("Ec618", 1)
    , Thread("Ec618Event")
    , queue_(xQueueCreate(32, sizeof(Event))) {
  ASSERT(instance() == null);
  if (queue_ == null) FATAL("Failed to allocate EC618 event queue");
  if (!spawn(4 * KB)) FATAL("Failed to start EC618 event worker");
  instance_.store(this, std::memory_order_release);
}

Ec618EventSource::~Ec618EventSource() {
  // Close producer admission before the blocking STOP send. A task sender
  // cannot be preempted by teardown while it holds a source pointer, and an
  // ISR on this single-core port completes before any task resumes.
  instance_.store(null, std::memory_order_release);
  Event stop_event = { Event::STOP, 0 };
  if (xQueueSend(queue_, &stop_event, portMAX_DELAY) != pdTRUE) FATAL("Failed to stop EC618 event worker");
  join();
  vQueueDelete(queue_);
}

void Ec618EventSource::on_unregister_resource(Locker& locker, Resource* r) {
  // Nothing special needed.
}

void Ec618EventSource::send_event(Event::Type type, word data) {
  taskENTER_CRITICAL();
  auto source = instance();
  if (source != null && source->mailbox_.publish(type, data)) {
    Event event = { type, data };
    xQueueSend(source->queue_, &event, 0);
  }
  taskEXIT_CRITICAL();
}

void Ec618EventSource::send_event_from_isr(Event::Type type, word data) {
  auto source = instance();
  if (source == null || !source->mailbox_.publish(type, data)) return;
  Event event = { type, data };
  BaseType_t xHigherPriorityTaskWoken = pdFALSE;
  xQueueSendFromISR(source->queue_, &event, &xHigherPriorityTaskWoken);
  portYIELD_FROM_ISR(xHigherPriorityTaskWoken);
}

void Ec618EventSource::dispatch_event(Locker& locker, Event::Type type, word data) {
  for (auto r : resources()) {
    auto er = static_cast<EventResource*>(r);
    if (er->event_type() == type) dispatch(locker, r, data);
  }
}

void Ec618EventSource::entry() {
  while (true) {
    Event event;
    if (xQueueReceive(queue_, &event, portMAX_DELAY) != pdTRUE) continue;
    if (event.type == Event::STOP) break;

    Locker locker(mutex());
    // Retained events use queue entries only as wake-up tokens. Even when a
    // token could not fit, every consumed entry drains all peripheral state.
    if (!Ec618EventMailbox::retains(event.type)) {
      dispatch_event(locker, event.type, event.data);
    }
    mailbox_.drain([&](Event::Type type, uint32_t data) {
      dispatch_event(locker, type, data);
    });
  }
}

}  // namespace toit

#endif  // TOIT_EC618
