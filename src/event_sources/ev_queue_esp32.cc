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

#include <driver/gpio.h>

#include "../objects_inline.h"
#include "../process.h"

#include "system_esp32.h"
#include "ev_queue_esp32.h"

namespace toit {

EventQueueEventSource* EventQueueEventSource::instance_ = null;

EventQueueEventSource::EventQueueEventSource()
    : EventSource("EVQ")
    , Thread("EVQ")
    , stop_(xSemaphoreCreateBinary())
    , gpio_queue_(xQueueCreate(32, sizeof(GpioEvent)))
    , queue_set_(xQueueCreateSet(32)) {
  xQueueAddToSet(stop_, queue_set_);
  xQueueAddToSet(gpio_queue_, queue_set_);

  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(gpio_install_isr_service(ESP_INTR_FLAG_IRAM));
  });

  // Create OS thread to handle events.
  spawn();

  ASSERT(instance_ == null);
  instance_ = this;
}

EventQueueEventSource::~EventQueueEventSource() {
  xSemaphoreGive(stop_);

  join();

  SystemEventSource::instance()->run([&]() -> void {
    gpio_uninstall_isr_service();
  });

  vQueueDelete(queue_set_);
  vQueueDelete(gpio_queue_);
  vSemaphoreDelete(stop_);
  instance_ = null;
}

void EventQueueEventSource::entry() {
  Locker locker(mutex());
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);

  while (true) {
    { Unlocker unlock(locker);
      // Wait for any queue/semaphore to wake up.
      xQueueSelectFromSet(queue_set_, portMAX_DELAY);
    }

    // First test if we should shut down.
    if (xSemaphoreTake(stop_, 0)) {
      return;
    }

    // See if there's a GPIO event.
    GpioEvent data;
    while (xQueueReceive(gpio_queue_, &data, 0)) {
      for (auto r : resources()) {
        auto resource = static_cast<EventQueueResource*>(r);
        if (resource->check_gpio(data.pin)) {
          dispatch(locker, r, data.timestamp);
        }
      }
    }

    // Then loop through other queues.
    for (auto r : resources()) {
      auto resource = static_cast<EventQueueResource*>(r);
      word data;
      while (resource->receive_event(&data)) {
        dispatch(locker, r, data);
      }
    }
  }
}

void EventQueueEventSource::on_register_resource(Locker& locker, Resource* r) {
  auto resource = static_cast<EventQueueResource*>(r);
  QueueHandle_t queue = resource->queue();
  if (queue == null) return;
  // We can only add to the queue set when the queue is empty, so we
  // repeatedly try to drain the queue before adding it to the set.
  int attempts = 0;
  do {
    if (attempts++ > 16) FATAL("couldn't register event resource");
    word data;
    while (resource->receive_event(&data)) {
      dispatch(locker, r, data);
    }
  } while (xQueueAddToSet(queue, queue_set_) != pdPASS);
}

void EventQueueEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  auto resource = static_cast<EventQueueResource*>(r);
  QueueHandle_t queue = resource->queue();
  if (queue == null) return;
  // We can only remove from the queue set when the queue is empty, so we
  // repeatedly try to drain the queue before removing it from the set.
  int attempts = 0;
  do {
    if (attempts++ > 16) FATAL("couldn't unregister event resource");
    word data;
    while (resource->receive_event(&data)) {
      // Don't dispatch while unregistering.
    }
  } while (xQueueRemoveFromSet(queue, queue_set_) != pdPASS);
}

} // namespace toit

#endif // TOIT_FREERTOS
