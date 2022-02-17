// Copyright (C) 2022 Toitware ApS.
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

namespace toit {

#include "rmt_esp32.h"
#include "driver/rmt.h"

RMTEventSource* RMTEventSource::_instance = null;

RMTEventSource::RMTEventSource()
    : EventSource("RMT")
    , Thread("RMT") {
  SystemEventSource::instance()->run([&]() -> void {
    // TODO
  });

  // Create OS thread to handle RMT events.
  spawn();

  ASSERT(_instance == null);
  _instance = this;
}

GPIOEventSource::~GPIOEventSource() {
  join();

  _instance = null;
}

void GPIOEventSource::entry() {
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);
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

void GPIOEventSource::on_register_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  // TODO
}

void GPIOEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  // TODO
  });
}

} // namespace toit

#endif  // TOIT_FREERTOS
