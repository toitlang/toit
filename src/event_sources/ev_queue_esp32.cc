// Copyright (C) 2018 Toitware ApS.
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

#ifdef TOIT_FREERTOS

#include "../objects_inline.h"
#include "../process.h"

#include "ev_queue_esp32.h"

namespace toit {

EventQueueEventSource* EventQueueEventSource::_instance = null;

EventQueueEventSource::EventQueueEventSource()
    : EventSource("EVQ")
    , Thread("EVQ")
    , _stop(xSemaphoreCreateBinary())
    , _queue_set(xQueueCreateSet(32)) {
  xQueueAddToSet(_stop, _queue_set);

  // Create OS thread to handle UART.
  spawn();

  ASSERT(_instance == null);
  _instance = this;
}

EventQueueEventSource::~EventQueueEventSource() {
  xSemaphoreGive(_stop);

  join();

  vQueueDelete(_queue_set);
  vSemaphoreDelete(_stop);
  _instance = null;
}

void EventQueueEventSource::entry() {
  Locker locker(mutex());
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);

  while (true) {
    { Unlocker unlock(locker);
      // Wait for any queue/semaphore to wake up.
      xQueueSelectFromSet(_queue_set, portMAX_DELAY);
    }

    // First test if we should shut down.
    if (xSemaphoreTake(_stop, 0)) {
      return;
    }

    // Then loop through all queues.
    for (auto r : resources()) {
      EventQueueResource* evq_res = static_cast<EventQueueResource*>(r);
      uart_event_t event;
      while (xQueueReceive(evq_res->queue(), &event, 0)) {
        dispatch(locker, r, event.type);
      }
    }
  }
}

void EventQueueEventSource::on_register_resource(Locker& locker, Resource* r) {
  EventQueueResource* evq_res = static_cast<EventQueueResource*>(r);
  // We can only add to the queue set when the queue is empty, so we
  // repeatedly try to drain the queue before adding it to the set.
  int attempts = 0;
  do {
    if (attempts++ > 16) FATAL("couldn't register UART resource");
    uart_event_t event;
    while (xQueueReceive(evq_res->queue(), &event, 0));
  } while (xQueueAddToSet(evq_res->queue(), _queue_set) != pdPASS);
}

void EventQueueEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  EventQueueResource* evq_res = static_cast<EventQueueResource*>(r);
  // We can only remove from the queue set when the queue is empty, so we
  // repeatedly try to drain the queue before removing it from the set.
  int attempts = 0;
  do {
    if (attempts++ > 16) FATAL("couldn't unregister UART resource");
    uart_event_t event;
    while (xQueueReceive(evq_res->queue(), &event, 0));
  } while (xQueueRemoveFromSet(evq_res->queue(), _queue_set) != pdPASS);
}

} // namespace toit

#endif // TOIT_FREERTOS
