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

#pragma once

#include <functional>

#include "../resource.h"

#include <host/ble_gap.h>

namespace toit {

class BLEResourceGroup;

class BLEResource : public Resource {
 public:
  enum Kind {
    GAP,
    GATT,
  };
  BLEResource(ResourceGroup* group, Kind kind)
      : Resource(group)
      , _kind(kind) {}

  Kind kind() const { return _kind; }

 private:
  const Kind _kind;
};

class GAPResource : public BLEResource {
 public:
  TAG(GAPResource);
  GAPResource(ResourceGroup* group)
      : BLEResource(group, GAP) {}
};

class GATTResource : public BLEResource {
 public:
  TAG(GATTResource);
  GATTResource(ResourceGroup* group, uint16 handle)
      : BLEResource(group, GATT)
      , _handle(handle)
      , _mutex(OS::allocate_mutex(3, "")) {}

  ~GATTResource() {
    if (_mbuf) os_mbuf_free(_mbuf);
    OS::dispose(_mutex);
  }

  uint16 handle() const { return _handle; }

  uint32 error() const {
    Locker locker(_mutex);
    return _error;
  }
  void set_error(uint32 error) {
    Locker locker(_mutex);
    _result = 0;
    _error = error;
  }

  uint32 result() const {
    Locker locker(_mutex);
    return _result;
  }
  void set_result(uint32 result) {
    Locker locker(_mutex);
    _result = result;
    _error = 0;
  }

  const struct os_mbuf* mbuf() const {
    Locker locker(_mutex);
    return _mbuf;
  }
  void set_mbuf(struct os_mbuf* mbuf) {
    Locker locker(_mutex);
    if (_mbuf) os_mbuf_free(_mbuf);
    _mbuf = mbuf;
    _error = 0;
  }

 private:
  uint16 _handle;
  Mutex* _mutex;
  uint32 _result = 0;
  uint32 _error = 0;
  struct os_mbuf* _mbuf = null;
};

class BLEEventSource : public LazyEventSource, public Thread {
 public:
  static BLEEventSource* instance();

  BLEEventSource();
  ~BLEEventSource();

  virtual bool start() override;
  virtual void stop() override;

  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static int on_gap(struct ble_gap_event* event, void* arg);
  static int on_gatt_service(uint16_t conn_handle,
                             const struct ble_gatt_error *error,
                             const struct ble_gatt_svc *service,
                             void *arg);
  static int on_gatt_characteristic(uint16_t conn_handle,
                                    const struct ble_gatt_error *error,
                                    const struct ble_gatt_chr *chr,
                                    void *arg);
  static int on_gatt_attribute(uint16_t conn_handle,
                               const struct ble_gatt_error *error,
                               struct ble_gatt_attr *attr,
                               void* arg);
  static void on_started();

 protected:
  friend class LazyEventSource;
  static BLEEventSource* _instance;

 private:
  void entry() override;

  void on_gap_event(struct ble_gap_event* event, Resource* resource);
  void on_gatt_service_event(uint16_t conn_handle,
                             const struct ble_gatt_error *error,
                             const struct ble_gatt_svc *service,
                             GATTResource* gatt);
  void on_gatt_characteristic_event(uint16_t conn_handle,
                                    const struct ble_gatt_error *error,
                                    const struct ble_gatt_chr *chr,
                                    GATTResource* gatt);
  void on_gatt_attribute_event(uint16_t conn_handle,
                               const struct ble_gatt_error *error,
                               struct ble_gatt_attr *attr,
                               GATTResource* gatt);
  void on_started_event();

  ConditionVariable* _resources_changed = null;
  bool _running = false;
  bool _should_run = false;
  bool _stop = false;
};

} // namespace toit
