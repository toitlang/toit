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

const int kInvalidHandle = UINT16_MAX;

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
  GATTResource(ResourceGroup* group)
      : BLEResource(group, GATT)
      , _mutex(OS::allocate_mutex(3, "")) {}

  ~GATTResource() {
    if (_mbuf) os_mbuf_free(_mbuf);
    OS::dispose(_mutex);
  }

  uint16 handle() const { return _handle; }
  void set_handle(uint16 handle) { _handle = handle; }

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
  uint16 _handle = kInvalidHandle;
  Mutex* _mutex;
  uint32 _result = 0;
  uint32 _error = 0;
  struct os_mbuf* _mbuf = null;
};


class BLEServerServiceResource;
typedef LinkedList<BLEServerServiceResource> BLEServerServiceList;

class BLEServerCharacteristicResource;
typedef LinkedList<BLEServerCharacteristicResource> BLEServerCharacteristicList;

class BLEServerCharacteristicResource: public Resource, public BLEServerCharacteristicList::Element {
 public:
  TAG(BLEServerCharacteristicResource);
  BLEServerCharacteristicResource(ResourceGroup* resource_group, BLEServerServiceResource* service,
                                  ble_uuid_any_t uuid, int type, os_mbuf* value, Mutex* mutex):
      Resource(resource_group),
      _service(service),
      _uuid(uuid),
      _type(type),
      _mbuf_to_send(value),
      _nimble_value_handle(0),
      _mbuf_received(null),
      _indicate(false),
      _notify(false),
      _conn_handle(0),
      _mutex(mutex) {}

  ~BLEServerCharacteristicResource() override;
  ble_uuid_any_t uuid() const { return _uuid; }
  ble_uuid_t* ptr_uuid() { return &_uuid.u; }
  int type() const { return _type; }
  uint16_t* ptr_nimble_value_handle() { return &_nimble_value_handle; }
  uint16_t nimble_value_handle() const { return _nimble_value_handle; }
  bool is_notify_enabled() const { return _notify; }
  bool is_indicate_enabled() const { return _indicate; }
  uint16 conn_handle() const { return _conn_handle; }

  os_mbuf* mbuf_to_send();
  void set_mbuf_to_send(os_mbuf* mbuf);

  void set_mbuf_received(os_mbuf* mbuf);
  os_mbuf* mbuf_received();

  void set_subscription_status(bool indicate, bool notify, uint16 conn_handle) {
    _indicate = indicate;
    _notify = notify;
    _conn_handle = conn_handle;
  }

 private:
  BLEServerServiceResource* _service;
  ble_uuid_any_t _uuid;
  int _type;
  os_mbuf* _mbuf_to_send;
  uint16 _nimble_value_handle;
  os_mbuf* _mbuf_received;
  bool _indicate;
  bool _notify;
  uint16 _conn_handle;
  Mutex* _mutex;
};

class BLEServerServiceResource: public Resource, public BLEServerServiceList::Element {
 public:
  TAG(BLEServerServiceResource);
  BLEServerServiceResource(ResourceGroup* resource_group, ble_uuid_any_t uuid):
      Resource(resource_group), _uuid(uuid){}

  ~BLEServerServiceResource() override {
    for (BLEServerCharacteristicResource* characteristic : _characteristics) {
      delete characteristic;
    }
  }

  BLEServerCharacteristicResource* add_characteristic(ble_uuid_any_t uuid, int type, os_mbuf* value, Mutex* mutex) {
    BLEServerCharacteristicResource* characteristic = _new BLEServerCharacteristicResource(resource_group(), this, uuid, type, value, mutex);
    if (characteristic != null) _characteristics.prepend(characteristic);
    return characteristic;
  }

  ble_uuid_any_t uuid() const { return _uuid; }
  ble_uuid_t* uuid_p() { return &_uuid.u; }
  BLEServerCharacteristicList characteristics() const { return _characteristics; }

 private:
  BLEServerCharacteristicList _characteristics;
  ble_uuid_any_t _uuid;
};



class BLEEventSource : public LazyEventSource, public Thread {
 public:
  static BLEEventSource* instance() { return _instance; }

  BLEEventSource();

  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  static int on_gap(struct ble_gap_event* event, void* arg);
  static int on_gatt_service(uint16_t conn_handle,
                             const struct ble_gatt_error* error,
                             const struct ble_gatt_svc* service,
                             void* arg);
  static int on_gatt_characteristic(uint16_t conn_handle,
                                    const struct ble_gatt_error* error,
                                    const struct ble_gatt_chr* chr,
                                    void* arg);
  static int on_gatt_attribute(uint16_t conn_handle,
                               const struct ble_gatt_error* error,
                               struct ble_gatt_attr* attr,
                               void* arg);
  static void on_started();

  static int on_gatt_server_characteristic(uint16_t conn_handle, uint16_t attr_handle,
                                           struct ble_gatt_access_ctxt* ctxt, void* arg);

 protected:
  friend class LazyEventSource;
  static BLEEventSource* _instance;

  ~BLEEventSource();

  virtual bool start() override;
  virtual void stop() override;

 private:
  void entry() override;

  void on_gap_event(struct ble_gap_event* event, Resource* resource);
  void on_gatt_service_event(uint16_t conn_handle,
                             const struct ble_gatt_error* error,
                             const struct ble_gatt_svc* service,
                             GATTResource* gatt);
  void on_gatt_characteristic_event(uint16_t conn_handle,
                                    const struct ble_gatt_error* error,
                                    const struct ble_gatt_chr* chr,
                                    GATTResource* gatt);
  void on_gatt_attribute_event(uint16_t conn_handle,
                               const struct ble_gatt_error* error,
                               struct ble_gatt_attr* attr,
                               GATTResource* gatt);
  int on_gatt_server_characteristic_event(ble_gatt_access_ctxt* ctxt,
                                          BLEServerCharacteristicResource* characteristic);
  void on_started_event();


  ConditionVariable* _resources_changed = null;
  bool _running = false;
  bool _should_run = false;
  bool _stop = false;
  static ble_gatt_access_fn* on_access;
};

} // namespace toit
