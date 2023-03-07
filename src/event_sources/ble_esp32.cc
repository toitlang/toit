// Copyright (C) 2021 Toitware ApS.
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

#if defined(TOIT_FREERTOS) && CONFIG_BT_ENABLED

#include "ble_esp32.h"
namespace toit {

BleEventSource* BleEventSource::instance_ = null;

BleEventSource::BleEventSource()
    : LazyEventSource("BLE", 1) {
  instance_ = this;
}

BleEventSource::~BleEventSource() {
  instance_ = null;
}

void BleEventSource::on_event(BleResource* resource, word data) {
  Locker locker(mutex());
  if (resource) dispatch(locker, resource, data);
}

bool BleEventSource::start() {
  return true;
}

void BleEventSource::stop() {}

} // namespace toit

#endif // TOIT_FREERTOS && CONFIG_BT_ENABLED
