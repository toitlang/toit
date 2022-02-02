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

#include "uart_esp32.h"

namespace toit {

UARTEventSource* UARTEventSource::_instance = null;

UARTEventSource::UARTEventSource()
    : EventSource("UART")
    , Thread("UART")
    , _stop(xSemaphoreCreateBinary())
    , _queue_set(xQueueCreateSet(32)) {
  xQueueAddToSet(_stop, _queue_set);

  // Create OS thread to handle UART.
  spawn();

  ASSERT(_instance == null);
  _instance = this;
}

UARTEventSource::~UARTEventSource() {
  xSemaphoreGive(_stop);

  join();

  vSemaphoreDelete(_stop);
  _instance = null;
}

void UARTEventSource::entry() {
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
      UARTResource* uart_res = static_cast<UARTResource*>(r);
      uart_event_t event;
      while (xQueueReceive(uart_res->queue(), &event, 0)) {
        dispatch(locker, r, event.type);
      }
    }
  }
}

void UARTEventSource::on_register_resource(Locker& locker, Resource* r) {
  UARTResource* uart_res = static_cast<UARTResource*>(r);
  // We can only add to the queue set when the queue is empty, so we
  // repeatedly try to drain the queue before adding it to the set.
  int attempts = 0;
  do {
    if (attempts++ > 16) FATAL("couldn't register UART resource");
    uart_event_t event;
    while (xQueueReceive(uart_res->queue(), &event, 0));
  } while (xQueueAddToSet(uart_res->queue(), _queue_set) != pdPASS);
}

void UARTEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  UARTResource* uart_res = static_cast<UARTResource*>(r);
  // We can only remove from the queue set when the queue is empty, so we
  // repeatedly try to drain the queue before removing it from the set.
  int attempts = 0;
  do {
    if (attempts++ > 16) FATAL("couldn't unregister UART resource");
    uart_event_t event;
    while (xQueueReceive(uart_res->queue(), &event, 0));
  } while (xQueueRemoveFromSet(uart_res->queue(), _queue_set) != pdPASS);
}

} // namespace toit

#endif // TOIT_FREERTOS
