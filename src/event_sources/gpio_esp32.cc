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

#include "../entropy_mixer.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../vm.h"
#include "system_esp32.h"
#include "gpio_esp32.h"

namespace toit {

GPIOEventSource* GPIOEventSource::_instance = null;

GPIOEventSource::GPIOEventSource()
    : EventSource("GPIO")
    , Thread("GPIO")
    , _stop(false)
    , _queue(xQueueCreate(32, sizeof(word))) {
  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(gpio_install_isr_service(ESP_INTR_FLAG_IRAM));
  });

  // Create OS thread to handle GPIO events.
  spawn();

  ASSERT(_instance == null);
  _instance = this;
}

GPIOEventSource::~GPIOEventSource() {
  word stop = -1;
  xQueueSendToFront(_queue, &stop, portMAX_DELAY);

  join();

  vQueueDelete(_queue);

  gpio_uninstall_isr_service();

  _instance = null;
}

void GPIOEventSource::entry() {
  while (true) {
    word id;
    if (xQueueReceive(_queue, &id, portMAX_DELAY) != pdTRUE) continue;
    if (id == -1) break;

    // Read value as fast as possible, for accuracy.
    uint32_t value = gpio_get_level(gpio_num_t(id));

    // Take lock and check that the resource still exists. If not, discard the result.
    Locker locker(mutex());
    IntResource* resource = find_resource_by_id(locker, id);
    if (resource == null) continue;
    dispatch(locker, resource, value);
    // TODO(anders): Consider using this event (time) as entropy source.
  }
}

void IRAM_ATTR GPIOEventSource::isr_handler(void* arg) {
  word id = unvoid_cast<word>(arg);
  xQueueSendToBackFromISR(_instance->_queue, &id, null);
}

void GPIOEventSource::on_register_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  IntResource* resource = static_cast<IntResource*>(r);
  word id = resource->id();
  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(gpio_isr_handler_add(gpio_num_t(id), isr_handler, reinterpret_cast<void*>(id)));
  });
}

void GPIOEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  IntResource* resource = static_cast<IntResource*>(r);
  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(gpio_isr_handler_remove(gpio_num_t(resource->id())));
  });
}

} // namespace toit

#endif // TOIT_FREERTOS
