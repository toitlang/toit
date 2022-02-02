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

#ifdef TOIT_FREERTOS

#include <esp_event.h>

#include "../os.h"
#include "../objects_inline.h"
#include "ble_esp32.h"

#include <nimble/nimble_port.h>
#include <nimble/nimble_port_freertos.h>

#include <host/ble_gap.h>
#include <host/ble_hs.h>
#include <host/util/util.h>

namespace toit {

BLEEventSource* BLEEventSource::_instance = null;

BLEEventSource::BLEEventSource()
    : LazyEventSource("BLE", 1)
    , Thread("BLE") {
  _instance = this;
}

BLEEventSource::~BLEEventSource() {
  ASSERT(_resources_changed == null);
  _instance = null;
}

bool BLEEventSource::start() {
  Locker locker(mutex());
  ASSERT(_resources_changed == null);
  _resources_changed = OS::allocate_condition_variable(mutex());
  if (_resources_changed == null) return false;
  if (!spawn()) {
    OS::dispose(_resources_changed);
    _resources_changed = null;
    return false;
  }
  _stop = false;
  return true;
}

void BLEEventSource::stop() {
  ASSERT(!_running);
  { // Stop the main thread.
    Locker locker(mutex());
    _stop = true;

    OS::signal(_resources_changed);
  }

  join();
  OS::dispose(_resources_changed);
  _resources_changed = null;
}

void BLEEventSource::entry() {
  Locker locker(mutex());
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);

  while (!_stop) {
    if (_should_run) {
      nimble_port_init();

      _running = true;
      OS::signal(_resources_changed);

      {
        Unlocker unlocker(locker);
        nimble_port_run();
      }

      nimble_port_freertos_deinit();
      _running = false;
      OS::signal(_resources_changed);
    }

    OS::wait(_resources_changed);
  }
}

void BLEEventSource::on_register_resource(Locker& locker, Resource* r) {
  BLEResource* ble = reinterpret_cast<BLEResource*>(r);
  switch (ble->kind()) {
    case BLEResource::GAP:
      _should_run = true;
      OS::signal(_resources_changed);

      while (!_running) {
        OS::wait(_resources_changed);
      }
      break;
    case BLEResource::GATT:
      break;
  }
}

void BLEEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  BLEResource* ble = reinterpret_cast<BLEResource*>(r);
  switch (ble->kind()) {
    case BLEResource::GAP:
      _should_run = false;
      {
        Unlocker unlocker(locker);
        FATAL_IF_NOT_ESP_OK(nimble_port_stop());
      }
      while (_running) {
        OS::wait(_resources_changed);
      }
      break;
    case BLEResource::GATT:
      ble_gap_terminate(reinterpret_cast<GATTResource*>(ble)->handle(), 0);
      break;
  }
}

void BLEEventSource::on_gap_event(struct ble_gap_event* event, Resource* resource) {
  Locker locker(mutex());
  dispatch(locker, resource, reinterpret_cast<word>(event));
}

int BLEEventSource::on_gap(struct ble_gap_event* event, void* arg) {
  instance()->on_gap_event(event, unvoid_cast<BLEResource*>(arg));
  return 0;
}

int BLEEventSource::on_gatt_service(uint16_t conn_handle,
                                    const struct ble_gatt_error *error,
                                    const struct ble_gatt_svc *service,
                                    void *arg) {
  GATTResource* gatt = unvoid_cast<GATTResource*>(arg);
  instance()->on_gatt_service_event(conn_handle, error, service, gatt);
  return 0;
}

void BLEEventSource::on_gatt_service_event(uint16_t conn_handle,
                                           const struct ble_gatt_error *error,
                                           const struct ble_gatt_svc *service,
                                           GATTResource* gatt) {
  switch (error->status) {
    case 0:
      gatt->set_result((service->start_handle << 16) | service->end_handle);
      return;

    case BLE_HS_EDONE:
      break;

    default:
      gatt->set_error(error->status);
      break;
  }

  Locker locker(mutex());
  dispatch(locker, gatt, 0);
}

int BLEEventSource::on_gatt_characteristic(uint16_t conn_handle,
                                           const struct ble_gatt_error *error,
                                           const struct ble_gatt_chr *chr,
                                           void *arg) {
  GATTResource* gatt = unvoid_cast<GATTResource*>(arg);
  instance()->on_gatt_characteristic_event(conn_handle, error, chr, gatt);
  return 0;
}

void BLEEventSource::on_gatt_characteristic_event(uint16_t conn_handle,
                                                  const struct ble_gatt_error *error,
                                                  const struct ble_gatt_chr *chr,
                                                  GATTResource* gatt) {
  switch (error->status) {
    case 0:
      gatt->set_result((chr->val_handle << 16) | chr->def_handle);
      return;

    case BLE_HS_EDONE:
      break;

    default:
      gatt->set_error(error->status);
      break;
  }

  Locker locker(mutex());
  dispatch(locker, gatt, 0);
}

int BLEEventSource::on_gatt_attribute(uint16_t conn_handle,
                                      const struct ble_gatt_error *error,
                                      struct ble_gatt_attr *attr,
                                      void* arg) {
  GATTResource* gatt = unvoid_cast<GATTResource*>(arg);
  instance()->on_gatt_attribute_event(conn_handle, error, attr, gatt);
  return 0;
}

void BLEEventSource::on_gatt_attribute_event(uint16_t conn_handle,
                                             const struct ble_gatt_error *error,
                                             struct ble_gatt_attr *attr,
                                             GATTResource* gatt) {
  switch (error->status) {
    case 0:
      gatt->set_mbuf(attr->om);
      // Take ownership of the buffer.
      attr->om = null;
      break;

    case BLE_HS_EDONE:
      break;

    default:
      gatt->set_error(error->status);
      break;
  }

  Locker locker(mutex());
  dispatch(locker, gatt, 0);
}

void BLEEventSource::on_started_event() {
  Locker locker(mutex());
  for (auto resource : resources()) {
    dispatch(locker, resource, 0);
  }
}

void BLEEventSource::on_started() {
  instance()->on_started_event();
}

} // namespace toit

#endif // TOIT_FREERTOS
