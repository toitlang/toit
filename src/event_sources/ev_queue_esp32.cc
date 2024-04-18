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

#ifdef TOIT_ESP32

#include <driver/gpio.h>

#include "../objects_inline.h"
#include "../process.h"

#include "system_esp32.h"
#include "ev_queue_esp32.h"

// The max queue set size is the maximum number of events in the queue. This is used for the gpio queue,
// up to two UART queues and the stop semaphore.
#define MAX_QUEUE_SET_SIZE (GPIO_QUEUE_SIZE + 2 * UART_QUEUE_SIZE + 1)

namespace toit {

EventQueueEventSource* EventQueueEventSource::instance_ = null;

EventQueueEventSource::EventQueueEventSource()
    : EventSource("EVQ")
    , Thread("EVQ")
    , stop_(xSemaphoreCreateBinary())
    , gpio_queue_(xQueueCreate(GPIO_QUEUE_SIZE, sizeof(GpioEvent)))
    , queue_set_(xQueueCreateSet(MAX_QUEUE_SET_SIZE)) {
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
    QueueSetMemberHandle_t handle;
    { Unlocker unlock(locker);
      // Wait for any queue/semaphore to wake up.
      handle = xQueueSelectFromSet(queue_set_, portMAX_DELAY);
    }

    // The handle is now the queue/semaphore that has woken up. Remove at most one event from the underlying queues,
    // so that the queue set does not overflow. If the queues are emptied at a different rate than the queue set, then
    // the queue might have free space where the queue set does not have free space.

    // First test if we should shut down.
    if (handle == stop_) {
      if (xSemaphoreTake(stop_, 0)) {
        return;
      }
    } else if (handle == gpio_queue_) {
      // See if there's a GPIO event.
      GpioEvent data;
      if (xQueueReceive(gpio_queue_, &data, 0)) {
        for (auto r : resources()) {
          auto resource = static_cast<EventQueueResource*>(r);
          if (resource->check_gpio(data.pin)) {
            dispatch(locker, r, data.timestamp);
          }
        }
      }
    } else {
      // Then loop through other queues.
      for (auto r: resources()) {
        auto resource = static_cast<EventQueueResource*>(r);
        if (resource->queue() == handle) {
          word data;
          if (resource->receive_event(&data)) {
            dispatch(locker, r, data);
          }
        }
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

#endif // TOIT_ESP32
