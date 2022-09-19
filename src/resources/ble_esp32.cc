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

#include "ble.h"

#include "../resource.h"
#include "../objects.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../primitive.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/ble_esp32.h"
#include "../event_sources/system_esp32.h"

#include <esp_bt.h>
#include <esp_wifi.h>
#include <esp_coexist.h>
#include <esp_nimble_hci.h>
#include <nimble/nimble_port.h>
#include <nimble/nimble_port_freertos.h>
#include <host/ble_hs.h>
#include <host/util/util.h>
#include <nvs_flash.h>
#include <host/ble_gap.h>
#include <services/gap/ble_svc_gap.h>
#include <host/ble_gap.h>
#include <services/gatt/ble_svc_gatt.h>


namespace toit {

const int kInvalidBLE = -1;
const int kInvalidHandle = UINT16_MAX;

// Only allow one instance of BLE running.
ResourcePool<int, kInvalidBLE> ble_pool(
    0
);

enum {
  kBLECharReceived = 1 << 0,
  kBLECharAccessed = 1 << 1,
  kBLECharSubscribed = 1 << 2,
};

enum {
  kBLECharTypeReadOnly = 1,
  kBLECharTypeWriteOnly = 2,
  kBLECharTypeReadWrite = 3,
  kBLECharTypeNotification = 4,
  kBLECharTypeWriteOnlyNoRsp = 5,
};

const uint8 kBluetoothBaseUUID[16] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB,
};

class DiscoveredPeripheral;
typedef DoubleLinkedList<DiscoveredPeripheral> DiscoveredPeripheralList;

class DiscoveredPeripheral : public DiscoveredPeripheralList::Element {
 public:
  DiscoveredPeripheral(ble_addr_t addr, int8_t rssi, uint8_t* data, uint8_t data_length)
      : _addr(addr)
      , _rssi(rssi)
      , _data(data)
      , _data_length(data_length) {}
  ~DiscoveredPeripheral() {
    free(_data);
  }

  ble_addr_t addr() { return _addr; }
  int8_t rssi() const { return _rssi; }
  uint8* data() { return _data; }
  uint8_t data_length() const { return _data_length; }

 private:
  ble_addr_t _addr{};
  int8_t _rssi = 0;
  uint8* _data = null;
  uint8_t _data_length = 0;
};


class BLEResourceGroup : public ResourceGroup, public Thread{
 public:
  TAG(BLEResourceGroup);
  BLEResourceGroup(Process* process, BLEEventSource* event_source, int id)
      : ResourceGroup(process, event_source)
      , Thread("BLE")
      , _id(id)
      , _sync(false) {
    Locker locker(_instance_access_mutex);
    ASSERT(!_instance);
    _instance = this;
  }

  void tear_down() override {
    FATAL_IF_NOT_ESP_OK(nimble_port_stop());
    join();

    nimble_port_deinit();

    FATAL_IF_NOT_ESP_OK(esp_nimble_hci_and_controller_deinit());

    ble_pool.put(_id);

    ResourceGroup::tear_down();
  }

  static BLEResourceGroup* instance() { return _instance; };
  static Mutex* instance_access_mutex() { return _instance_access_mutex; };

  void set_sync(bool sync) {
    for(Resource *resource : resources()) {
      auto ble_resource = reinterpret_cast<BLEResource*>(resource);
      BLEEventSource::instance()->on_event(ble_resource, kBLEStarted);
    }
  }

  bool sync() { return _sync; }

 public:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

 protected:
  void entry() override{
    nimble_port_run();
  }
  ~BLEResourceGroup() override {
    Locker locker(_instance_access_mutex);
    _instance = null;
  };

 private:
  int _id;
  bool _sync;
  static BLEResourceGroup* _instance;
  static Mutex* _instance_access_mutex;


};

// There can be only one active BLEResourceGroup. This reference will be
// active when the resource group exists
BLEResourceGroup* BLEResourceGroup::_instance = null;
Mutex* BLEResourceGroup::_instance_access_mutex = OS::allocate_mutex(3,"BLE");

class BLECharacteristicResource;
typedef DoubleLinkedList<BLECharacteristicResource> CharacteristicResourceList;
class BLEServiceResource;
class BLECharacteristicResource : public BLEResource, public CharacteristicResourceList::Element {
 public:
  TAG(BLECharacteristicResource);
  BLECharacteristicResource(BLEResourceGroup *group, BLEServiceResource* service,
                            ble_uuid_any_t uuid, uint8 properties, uint16 value_handle)
      : BLEResource(group, CHARACTERISTIC)
      , _service(service)
      , _uuid(uuid)
      , _properties(properties)
      , _value_handle(value_handle)
      , _mbuf_received(null)
      , _error(0) {}

  ble_uuid_any_t& uuid() { return _uuid; }
  BLEServiceResource* service() const { return _service; }
  uint8 properties() const { return _properties;  }
  uint16 value_handle() const { return _value_handle; }
  void set_error(int error) { _error = error; }
  int error() { return _error; }
  void set_mbuf_received(os_mbuf* mbuf)  {
    Locker locker(BLEResourceGroup::instance_access_mutex());
    if (_mbuf_received == null)  {
      _mbuf_received = mbuf;
    } else if (mbuf == null) {
      os_mbuf_free_chain(_mbuf_received);
      _mbuf_received = null;
    } else {
      os_mbuf_concat(_mbuf_received, mbuf);
    }
  };

  os_mbuf* mbuf_received() {
    Locker locker(BLEResourceGroup::instance_access_mutex());
    return _mbuf_received;
  }


  void on_attribute_read_event(const struct ble_gatt_error *error,
                               struct ble_gatt_attr *attr);

  static int on_attribute_read(uint16_t conn_handle,
                               const struct ble_gatt_error *error,
                               struct ble_gatt_attr *attr,
                               void *arg) {
    unvoid_cast<BLECharacteristicResource*>(arg)->on_attribute_read_event(error, attr);
    return 0;
  }
 private:
  BLEServiceResource* _service;
  ble_uuid_any_t _uuid;
  uint8 _properties;
  uint16 _value_handle;
  os_mbuf* _mbuf_received;
  int _error;
};

class BLEServiceResource;
typedef DoubleLinkedList<BLEServiceResource> ServiceResourceList;
class BLERemoteDeviceResource;

class BLEServiceResource: public BLEResource, public ServiceResourceList::Element {
 public:
  TAG(BLEServiceResource);
  BLEServiceResource(BLEResourceGroup* group, BLERemoteDeviceResource* device, ble_uuid_any_t uuid, uint16 start_handle, uint16 end_handle)
      : BLEResource(group, SERVICE)
      , _uuid(uuid)
      , _start_handle(start_handle)
      , _end_handle(end_handle)
      , _device(device) {}

  ~BLEServiceResource() override {
    while ( _characteristics.remove_first() ) ;
  }

  BLECharacteristicResource* get_or_create_characteristics_resource(
      ble_uuid_any_t uuid, uint8 properties, uint16 def_handle, uint16 value_handle, bool can_create=false);
//
//  BLEServerCharacteristicResource* add_characteristic(ble_uuid_any_t uuid, int type, os_mbuf* value, Mutex* mutex) {
//    BLEServerCharacteristicResource* characteristic = _new BLEServerCharacteristicResource(resource_group(), this, uuid, type, value, mutex);
//    if (characteristic != null) _characteristics.prepend(characteristic);
//    return characteristic;
//  }

  ble_uuid_any_t& uuid() { return _uuid; }
  ble_uuid_t* uuid_p() { return &_uuid.u; }
  uint16 start_handle() const { return _start_handle; }
  uint16 end_handle() const { return _end_handle; }

  BLERemoteDeviceResource* device() const { return _device;}
  CharacteristicResourceList& characteristics() { return _characteristics; }

  void on_characteristics_discover_event(const struct ble_gatt_error *error,
                                         const struct ble_gatt_chr *chr) {
    switch (error->status) {
      case 0:
        get_or_create_characteristics_resource(
            chr->uuid, chr->properties, chr->def_handle, chr->val_handle,true);
        break;
      case BLE_HS_EDONE:
        BLEEventSource::instance()->on_event(this, kBLECharacteristicsDiscovered);
        break;
    }
  }

  static int on_characteristics_discover(uint16_t conn_handle,
                                               const struct ble_gatt_error *error,
                                               const struct ble_gatt_chr *chr, void *arg) {
    unvoid_cast<BLEServiceResource*>(arg)->on_characteristics_discover_event(error, chr);
    return 0;

  }
 private:
  CharacteristicResourceList _characteristics;
  ble_uuid_any_t _uuid;
  uint16 _start_handle;
  uint16 _end_handle;
  BLERemoteDeviceResource *_device;
};


class BLECentralManagerResource : public BLEResource {
 public:
  TAG(BLECentralManagerResource);

  explicit BLECentralManagerResource(BLEResourceGroup* group)
      : BLEResource(group, CENTRAL_MANAGER)
      , _mutex(OS::allocate_mutex(3, "")) {}

  ~BLECentralManagerResource() override {
    if (is_scanning()) {
      FATAL_IF_NOT_ESP_OK(ble_gap_disc_cancel());
    }
    while (remove_discovered_peripheral()) {}
  }

  static bool is_scanning() { return ble_gap_disc_active(); }

  DiscoveredPeripheral* get_discovered_peripheral() {
    return _newly_discovered_peripherals.first();
  }

  DiscoveredPeripheral* remove_discovered_peripheral() {
    return _newly_discovered_peripherals.remove_first();
  }

  void on_discovery_event(ble_gap_event *event);

  static int on_discovery(ble_gap_event *event, void *arg) {
    unvoid_cast<BLECentralManagerResource*>(arg)->on_discovery_event(event);
    return 0;
  };

  Mutex* mutex() { return _mutex; }
 private:
  DiscoveredPeripheralList _newly_discovered_peripherals;
  Mutex* _mutex;
};

template <typename T>
class ServiceContainer : public BLEResource {
 public:
  ServiceContainer(BLEResourceGroup* group, Kind kind)
      : BLEResource(group, kind) {}

  virtual T* type() = 0;
  BLEServiceResource* get_or_create_service_resource(ble_uuid_any_t uuid, uint16 start, uint16 end, bool can_create=false);
  ServiceResourceList& services() { return _services; }
 private:
  ServiceResourceList _services;
};


class BLEPeripheralManagerResource : public ServiceContainer<BLEPeripheralManagerResource> {
 public:
  TAG(BLEPeripheralManagerResource);
  explicit BLEPeripheralManagerResource(BLEResourceGroup* group)
  : ServiceContainer(group, PERIPHERAL_MANAGER) {}

  ~BLEPeripheralManagerResource() override {
    if (is_advertising()) {
      FATAL_IF_NOT_ESP_OK(ble_gap_adv_stop());
    }
  }

  BLEPeripheralManagerResource* type() override { return this; }

  static bool is_advertising() { return ble_gap_adv_active(); }
};

class BLERemoteDeviceResource : public ServiceContainer<BLERemoteDeviceResource> {
 public:
  TAG(BLERemoteDeviceResource);
  explicit BLERemoteDeviceResource(BLEResourceGroup* group)
    : ServiceContainer(group, REMOTE_DEVICE)
    , _handle(kInvalidHandle) {}

  BLERemoteDeviceResource* type() override { return this; }

  void on_event(ble_gap_event *event);

  static int on_event(ble_gap_event *event, void *arg) {
    unvoid_cast<BLERemoteDeviceResource*>(arg)->on_event(event);
    return 0;
  };

  void on_service_discovered_event(const ble_gatt_error* error, const ble_gatt_svc* service);

  static int on_service_discovered(uint16_t conn_handle,
                                   const struct ble_gatt_error *error,
                                   const struct ble_gatt_svc *service,
                                   void *arg) {
    unvoid_cast<BLERemoteDeviceResource*>(arg)->on_service_discovered_event(error, service);
  }

  uint16 handle() const { return _handle; }
  void set_handle(uint16 handle) { _handle = handle; }
 private:
  uint16 _handle;

};



class BLEServerConfigGroup : public ResourceGroup {
 public:
  TAG(BLEServerConfigGroup);

  BLEServerConfigGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source)
      , _gatt_services(null)
      , _mutex(OS::allocate_mutex(3, "")) {
  }

  ~BLEServerConfigGroup() override {
    for (BLEServerServiceResource* service: _services) {
      delete service;
    }

    free_gatt_service_structure();
  }

  BLEServerServiceResource* add_service(ble_uuid_any_t uuid) {
    BLEServerServiceResource* service = _new BLEServerServiceResource(this, uuid);
    if (service != null) _services.prepend(service);
    return service;
  }

  BLEServerServiceList services() const { return _services; }

  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

  void set_subscription_status(uint16 attr_handle, uint16 conn_handle, bool indicate, bool notify);

  Mutex* mutex() { return _mutex; }

  void set_gatt_service_structure(ble_gatt_svc_def* gatt_services) {
    if (_gatt_services != null) free_gatt_service_structure();
    _gatt_services = gatt_services;
  }

  void free_gatt_service_structure() {
    if (_gatt_services != null) {
      ble_gatt_svc_def* cur = _gatt_services;
      while (cur->type) {
        free((void*) cur->characteristics);
        cur++;
      }
      free(_gatt_services);
      _gatt_services = null;
    }
  }

 private:
  BLEServerServiceList _services;
  ble_gatt_svc_def* _gatt_services;
  Mutex* _mutex;
};

static ble_uuid_any_t uuid_from_blob(Blob& blob) {
  ble_uuid_any_t uuid = {0};
  switch (blob.length()) {
    case 2: {
      uuid.u.type = BLE_UUID_TYPE_16;
      uint16 value = *reinterpret_cast<const uint16*>(blob.address());
      uuid.u16.value = __builtin_bswap16(value);
      break;
    }
    case 4: {
      uuid.u.type = BLE_UUID_TYPE_32;
      uint32 value = *reinterpret_cast<const uint32*>(blob.address());
      uuid.u32.value = __builtin_bswap32(value);
      break;
    }
    default:
      uuid.u.type = BLE_UUID_TYPE_128;
      memcpy_reverse(uuid.u128.value, blob.address(), 16);
  }
//  if (memcmp(kBluetoothBaseUUID+4, blob.address()+4, 12) == 0) {
//    // Check if it's 16 or 32 bytes.
//    if (memcmp(kBluetoothBaseUUID, blob.address(), 2) == 0) {
//      uuid.u.type = BLE_UUID_TYPE_16;
//      uint16 value = *reinterpret_cast<const uint16*>(blob.address() + 2);
//      uuid.u16.value = __builtin_bswap16(value);
//    } else {
//      uuid.u.type = BLE_UUID_TYPE_32;
//      uint32 value = *reinterpret_cast<const uint32*>(blob.address());
//      uuid.u32.value = __builtin_bswap32(value);
//    }
//  } else {
//    uuid.u.type = BLE_UUID_TYPE_128;
//    memcpy_reverse(uuid.u128.value, blob.address(), 16);
//  }
  return uuid;
}

static ByteArray* byte_array_from_uuid(Process* process, ble_uuid_any_t uuid, Error** err) {
  *err = null;

  ByteArray* byte_array = process->object_heap()->allocate_internal_byte_array(uuid.u.type/8);
  if (!byte_array) {
    *err = Error::from(process->program()->allocation_failed());
    return null;
  }
  ByteArray::Bytes bytes(byte_array);

  switch (uuid.u.type) {
    case BLE_UUID_TYPE_16:
      *reinterpret_cast<uint16*>(bytes.address()) = __builtin_bswap16(uuid.u16.value);
      break;
    case BLE_UUID_TYPE_32:
      *reinterpret_cast<uint32*>(bytes.address()) = __builtin_bswap16(uuid.u32.value);
      break;
    default:
      memcpy_reverse(bytes.address(), uuid.u128.value, sizeof(uuid.u128.value));
  }

  return byte_array;
}

bool uuid_equals(ble_uuid_any_t& uuid, ble_uuid_any_t& other) {
  if (uuid.u.type != other.u.type) return false;
  switch (uuid.u.type) {
    case BLE_UUID_TYPE_16:
      return uuid.u16.value == other.u16.value;
    case BLE_UUID_TYPE_32:
      return uuid.u32.value == other.u32.value;
    default:
      return !memcmp(uuid.u128.value, other.u128.value, sizeof(uuid.u128.value));
  }
}

static Object* convert_mbuf_to_heap_object(Process* process, const os_mbuf* mbuf) {
  int size = 0;
  for (const os_mbuf* current = mbuf; current; current = SLIST_NEXT(current, om_next)) {
    size += current->om_len;
  }
  ByteArray* data = process->object_heap()->allocate_internal_byte_array(size);
  if (!data) return null;
  ByteArray::Bytes bytes(data);
  int offset = 0;
  for (const os_mbuf* current = mbuf; current; current = SLIST_NEXT(current, om_next)) {
    memmove(bytes.address() + offset, current->om_data, current->om_len);
    offset += current->om_len;
  }
  return data;
}



uint32_t BLEResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
//  struct ble_gap_event* event = reinterpret_cast<struct ble_gap_event*>(data);
//
//  if (event == null) {
//    return state | kBLEStarted;
//  }
//
//  switch (event->type) {
//    case BLE_GAP_EVENT_ADV_COMPLETE:
//      state |= kBLECompleted;
//      break;
//
//    case BLE_GAP_EVENT_DISC: {
//      DiscoveredPeripheral* discovery = _new DiscoveredPeripheral();
//      if (!discovery) {
//        break;
//      }
//
//      if (!discovery->init(event->disc)) {
//        delete discovery;
//        break;
//      }
//
//      {
//        Locker locker(_mutex);
//        _discoveries.append(discovery);
//      }
//
//      state |= kBLEDiscovery;
//      break;
//    }
//
//    case BLE_GAP_EVENT_DISC_COMPLETE:
//      state |= kBLECompleted;
//      break;
//
//    case BLE_GAP_EVENT_CONNECT: {
//      if (event->connect.status == 0) {
//        auto ble_resource = resource->as<BLEResource*>();
//
//        // Success.
//        if (ble_resource->kind() == BLEResource::GATT) {
//          Locker locker(_mutex);
//          GATTResource* gatt = ble_resource->as<GATTResource*>();
//          ASSERT(gatt->handle() == kInvalidHandle);
//          gatt->set_handle(event->connect.conn_handle);
//        }
//        state &= ~kBLEDisconnected;
//        state |= kBLEConnected;
//      } else {
//        state |= kBLEConnectFailed;
//      }
//      break;
//    }
//
//    case BLE_GAP_EVENT_SUBSCRIBE:
//      if (_server_config != null) {
//        _server_config->set_subscription_status(event->subscribe.attr_handle, event->subscribe.conn_handle,
//                                                event->subscribe.cur_indicate, event->subscribe.cur_notify);
//      }
//      break;
//    case BLE_GAP_EVENT_DISCONNECT:
//      auto ble_resource = resource->as<BLEResource*>();
//      if (ble_resource->kind() == BLEResource::GATT) {
//        Locker locker(_mutex);
//        GATTResource* gatt = ble_resource->as<GATTResource*>();
//        ASSERT(gatt->handle() != kInvalidHandle);
//        gatt->set_handle(kInvalidHandle);
//        if (static_cast<ResourceList::Element*>(gatt)->is_not_linked()) {
//          delete gatt;
//        }
//      }
//      if (_server_config != null) {
//        state &= ~kBLEConnected;
//        state |= kBLEDisconnected;
//      }
//      break;
//  }
  USE(resource);
  state |= data;
  return state;
}

template<typename T>
BLEServiceResource*
ServiceContainer<T>::get_or_create_service_resource(ble_uuid_any_t uuid, uint16 start, uint16 end, bool can_create) {
  for (const auto &service: _services) {
    if (uuid_equals(uuid, service->uuid())) return service;
  }
  if (!can_create) return null;

  auto service = _new BLEServiceResource(group(),type(), uuid, start,end);
  if (!service) return null;
  group()->register_resource(service);
  _services.append(service);
  return service;
}

BLECharacteristicResource* BLEServiceResource::get_or_create_characteristics_resource(
    ble_uuid_any_t uuid, uint8 properties, uint16 def_handle,
    uint16 value_handle, bool can_create) {
  for (const auto &item: _characteristics) {
    if (uuid_equals(uuid, item->uuid())) return item;
  }
  if (!can_create) return null;

  auto characteristic = _new BLECharacteristicResource(group(), this, uuid, properties, value_handle);
  if (!characteristic) return null;
  group()->register_resource(characteristic);
  _characteristics.append(characteristic);
  return characteristic;
}


void BLECentralManagerResource::on_discovery_event(ble_gap_event* event) {
  uint8* data = null;
  uint8 data_length = 0;

  if (event->disc.length_data > 0) {
    data = unvoid_cast<uint8*>(malloc(event->disc.length_data));
    if (!data) return;
    memmove(data, event->disc.data, event->disc.length_data);
    data_length = event->disc.length_data;
  }

  auto discovered_peripheral
      = _new DiscoveredPeripheral(event->disc.addr, event->disc.rssi, data, data_length);

  if (!discovered_peripheral) {
    if (data) free(data);
    return;
  }

  {
    Locker locker(_mutex);
    _newly_discovered_peripherals.append(discovered_peripheral);
  }

  BLEEventSource::instance()->on_event(this, kBLEDiscovery);
}

void BLERemoteDeviceResource::on_event(ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (event->connect.status == 0) {
        ASSERT(handle() == kInvalidHandle);
        set_handle(event->connect.conn_handle);
        BLEEventSource::instance()->on_event(this, kBLEConnected);
      } else {
        BLEEventSource::instance()->on_event(this, kBLEConnectFailed);
      }
      break;
    case BLE_GAP_EVENT_DISCONNECT:
      BLEEventSource::instance()->on_event(this, kBLEDisconnected);
      break;
    case BLE_GAP_EVENT_NOTIFY_RX:
      // Notify/indicate update
      break;
  }
}

void BLERemoteDeviceResource::on_service_discovered_event(const ble_gatt_error* error, const ble_gatt_svc* service) {
  switch (error->status) {
    case 0:
      get_or_create_service_resource(service->uuid, service->start_handle, service->end_handle, true);
      break;
    case BLE_HS_EDONE:
      BLEEventSource::instance()->on_event(this, kBLEServicesDiscovered);
      break;
  }
}

void BLECharacteristicResource::on_attribute_read_event(
    const struct ble_gatt_error* error,
    struct ble_gatt_attr* attr) {
  switch (error->status) {
    case 0:
      set_mbuf_received(attr->om);
      // Take ownership of the buffer.
      attr->om = null;
      BLEEventSource::instance()->on_event(this, kBLEValueDataReady);
      break;

    case BLE_HS_EDONE:
      break;

    default:
      set_error(error->status);
      BLEEventSource::instance()->on_event(this, kBLEValueDataReadFailed);
      break;
  }

}


//
//int BLEResourceGroup::init_server() {
//  if (_server_config != null) {
//    ble_svc_gap_init();
//    ble_svc_gatt_init();
//
//    // Build the service structure.
//    int service_cnt = 0;
//    for (BLEServerServiceResource* t: _server_config->services()) {
//      USE(t);
//      service_cnt++;
//    }
//
//    auto gatt_services = static_cast<ble_gatt_svc_def*>(malloc((service_cnt + 1) * sizeof(ble_gatt_svc_def)));
//
//    gatt_services[service_cnt].type = 0;
//
//    int service_idx = 0;
//    for (BLEServerServiceResource* service: _server_config->services()) {
//      int characteristic_cnt = 0;
//      for (BLEServerCharacteristicResource* t: service->characteristics()) {
//        USE(t);
//        characteristic_cnt++;
//      }
//
//      auto gatt_svr_chars = static_cast<ble_gatt_chr_def*>(malloc(
//          (characteristic_cnt + 1) * sizeof(ble_gatt_chr_def)));
//
//      int characteristic_idx = 0;
//      for (BLEServerCharacteristicResource* characteristic: service->characteristics()) {
//        gatt_svr_chars[characteristic_idx].uuid = characteristic->ptr_uuid();
//        gatt_svr_chars[characteristic_idx].access_cb = BLEEventSource::on_gatt_server_characteristic;
//        gatt_svr_chars[characteristic_idx].arg = characteristic;
//        gatt_svr_chars[characteristic_idx].val_handle = characteristic->ptr_nimble_value_handle();
//
//        switch (characteristic->type()) {
//          case kBLECharTypeReadOnly:
//            gatt_svr_chars[characteristic_idx].flags = BLE_GATT_CHR_F_READ;
//            break;
//          case kBLECharTypeWriteOnly:
//            gatt_svr_chars[characteristic_idx].flags = BLE_GATT_CHR_F_WRITE;
//            break;
//          case kBLECharTypeWriteOnlyNoRsp:
//            gatt_svr_chars[characteristic_idx].flags = BLE_GATT_CHR_F_WRITE_NO_RSP;
//            break;
//          case kBLECharTypeReadWrite:
//            gatt_svr_chars[characteristic_idx].flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_READ;
//            break;
//          case kBLECharTypeNotification:
//            gatt_svr_chars[characteristic_idx].flags = BLE_GATT_CHR_F_NOTIFY;
//            break;
//        }
//
//        characteristic_idx++;
//      }
//
//      gatt_services[service_idx].type = BLE_GATT_SVC_TYPE_PRIMARY;
//      gatt_services[service_idx].uuid = service->uuid_p();
//      gatt_services[service_idx].characteristics = gatt_svr_chars;
//
//      service_idx++;
//    }
//
//    _server_config->set_gatt_service_structure(gatt_services);
//
//    int rc = ble_gatts_count_cfg(gatt_services);
//    if (rc != 0) {
//      _server_config->tear_down();
//      return rc;
//    }
//
//    rc = ble_gatts_add_svcs(gatt_services);
//    if (rc != 0) {
//      _server_config->tear_down();
//      return rc;
//    }
//
//  }
//
//  return ESP_OK;
//}


uint32_t BLEServerConfigGroup::on_event(Resource* resource, word data, uint32_t state) {
  switch (data) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
      state |= kBLECharAccessed;
      break;
    case BLE_GATT_ACCESS_OP_WRITE_CHR:
      state |= kBLECharReceived;
      break;
    default:
      break;
  }
  return state;
}

void BLEServerConfigGroup::set_subscription_status(uint16 attr_handle, uint16 conn_handle, bool indicate, bool notify) {
  for (auto service: _services) {
    for (auto characteristic: service->characteristics()) {
      if (characteristic->nimble_value_handle() == attr_handle) {
        characteristic->set_subscription_status(indicate, notify, conn_handle);
        return;
      }
    }
  }
}

static Object* object_to_mbuf(Process* process, Object* object, os_mbuf** result) {
  *result = null;
  if (object != process->program()->null_object()) {
    Blob bytes;
    if (!object->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
    if (bytes.length() > 0) {
      os_mbuf* mbuf = ble_hs_mbuf_from_flat(bytes.address(), bytes.length());
      // A null response is not an allocation error, as the mbufs are allocated on boot based on configuration settings.
      // Therefore, a GC will do little to help the situation and will eventually result in the VM thinking it is out of memory.
      // The mbuf will be freed eventually by the NimBLE stack. The client code will
      // have to wait and then try again.
      if (!mbuf) QUOTA_EXCEEDED;
      *result = mbuf;
    }
  }
  return null;  // No error.
}

static void ble_on_sync() {
  // Make sure we have proper identity address set (public preferred).
  int rc = ble_hs_util_ensure_addr(0);
  if (rc != 0) {
    FATAL("error setting address; rc=%d", rc);
  }
  Locker locker(BLEResourceGroup::instance_access_mutex());

  BLEResourceGroup *instance = BLEResourceGroup::instance();
  if (instance) {
    instance->set_sync(true);
  }
}

MODULE_IMPLEMENTATION(ble, MODULE_BLE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  int id = ble_pool.any();
  if (id == kInvalidBLE) ALREADY_IN_USE;

  esp_err_t err = esp_nimble_hci_and_controller_init();

  // TODO(anders): Enable these to improve BLE/WiFi coop?
  //SystemEventSource::instance()->run([&]() -> void {
    // esp_coex_preference_set(ESP_COEX_PREFER_BT);
    // esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
  //});
  if (err != ESP_OK) {
    ble_pool.put(id);
    if (err == ESP_ERR_NO_MEM) {
      esp_bt_controller_disable();
      esp_bt_controller_deinit();
      MALLOC_FAILED;
    }
    return Primitive::os_error(err, process);
  }

  // Mark usage. When the group is unregistered, the usage is automatically
  // decremented, but if group allocation fails, we manually call unuse().
  BLEEventSource* ble = BLEEventSource::instance();
  if (!ble->use()) {
    ble_pool.put(id);
    MALLOC_FAILED;
  }

  auto group = _new BLEResourceGroup(process, ble, id);
  if (!group) {
    ble->unuse();
    ble_pool.put(id);
    MALLOC_FAILED;
  }

  ble_hs_cfg.sync_cb = ble_on_sync;

  // NimBLE needs to be initialized before the server setup is executed.
  nimble_port_init();

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create_central_manager) {
  ARGS(BLEResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto central_manager = _new BLECentralManagerResource(group);
  if (!central_manager) MALLOC_FAILED;

  group->register_resource(central_manager);
  proxy->set_external_address(central_manager);

  if (group->sync()) BLEEventSource::instance()->on_event(central_manager, kBLEStarted);

  return proxy;
}

PRIMITIVE(create_peripheral_manager) {
  ARGS(BLEResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto peripheral_manager = _new BLEPeripheralManagerResource(group);
  if (!peripheral_manager) MALLOC_FAILED;

  group->register_resource(peripheral_manager);
  proxy->set_external_address(peripheral_manager);

  if (group->sync()) BLEEventSource::instance()->on_event(peripheral_manager, kBLEStarted);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(BLEResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(scan_start) {
  ARGS(BLECentralManagerResource, central_manager, int64, duration_us);

  if (BLECentralManagerResource::is_scanning()) ALREADY_EXISTS;

  int32 duration_ms = duration_us < 0 ? BLE_HS_FOREVER : static_cast<int>(duration_us / 1000);

  uint8_t own_addr_type;

  /* Figure out address to use while advertising (no privacy for now) */
  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  struct ble_gap_disc_params disc_params = { 0 };
  // Tell the controller to filter duplicates; we don't want to process
  // repeated advertisements from the same device.
  // disc_params.filter_duplicates = 1;

  /**
   * Perform a passive scan.  I.e., don't send follow-up scan requests to
   * each advertiser.
   */
  disc_params.passive = 1;

  /* Use defaults for the rest of the parameters. */
  disc_params.itvl = 0;
  disc_params.window = 0;
  disc_params.filter_policy = 0;
  disc_params.limited = 0;

  err = ble_gap_disc(BLE_ADDR_PUBLIC, duration_ms, &disc_params,
                     BLECentralManagerResource::on_discovery, central_manager);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BLECentralManagerResource, central_manager);
  Locker locker(central_manager->mutex());

  DiscoveredPeripheral* next = central_manager->get_discovered_peripheral();
  if (!next) return process->program()->null_object();

  Array* array = process->object_heap()->allocate_array(5, process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  ByteArray* id = process->object_heap()->allocate_internal_byte_array(7);
  if (!id) ALLOCATION_FAILED;
  ByteArray::Bytes id_bytes(id);
  id_bytes.address()[0] = next->addr().type;
  memcpy_reverse(id_bytes.address() + 1, next->addr().val, 6);
  array->at_put(0, id);

  array->at_put(1, Smi::from(next->rssi()));

  if (next->data_length() > 0) {
    ble_hs_adv_fields fields{};
    int rc = ble_hs_adv_parse_fields(&fields, next->data(), next->data_length());
    if (rc == 0) {
      if (fields.name_len > 0) {
        Error* error = null;
        String* name = process->allocate_string((const char*)fields.name, fields.name_len, &error);
        if (error) return error;
        array->at_put(2, name);
      }

      int uuids = fields.num_uuids16 + fields.num_uuids32 + fields.num_uuids128;
      Array* service_classes = process->object_heap()->allocate_array(uuids, Smi::from(0));
      if (!service_classes) ALLOCATION_FAILED;

      int index = 0;
      for (int i = 0; i < fields.num_uuids16; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(2);
        if (!service_class) ALLOCATION_FAILED;
        ByteArray::Bytes service_class_bytes(service_class);
        *reinterpret_cast<uint16*>(service_class_bytes.address()) = __builtin_bswap16(fields.uuids16[i].value);
        service_classes->at_put(index++, service_class);
      }

      for (int i = 0; i < fields.num_uuids32; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(4);
        if (!service_class) ALLOCATION_FAILED;
        ByteArray::Bytes service_class_bytes(service_class);
        *reinterpret_cast<uint32*>(service_class_bytes.address()) = __builtin_bswap32(fields.uuids32[i].value);
        service_classes->at_put(index++, service_class);
      }

      for (int i = 0; i < fields.num_uuids128; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(16);
        if (!service_class) ALLOCATION_FAILED;
        ByteArray::Bytes service_class_bytes(service_class);
        memcpy_reverse(service_class_bytes.address(), fields.uuids128[i].value, 16);
        service_classes->at_put(index++, service_class);
      }
      array->at_put(3, service_classes);

      if (fields.mfg_data_len > 0) {
        ByteArray* custom_data = process->object_heap()->allocate_internal_byte_array(fields.mfg_data_len);
        if (!custom_data) ALLOCATION_FAILED;
        ByteArray::Bytes custom_data_bytes(custom_data);
        memcpy(custom_data_bytes.address(), fields.mfg_data, fields.mfg_data_len);
        array->at_put(4, custom_data);
      }
    }
  }

  central_manager->remove_discovered_peripheral();

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(BLEResourceGroup, group);

  if (BLECentralManagerResource::is_scanning()) {
    int err = ble_gap_disc_cancel();
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
  }

  return process->program()->null_object();
}

PRIMITIVE(connect) {
  ARGS(BLECentralManagerResource, central_manager, Blob, address);

  uint8_t own_addr_type;

  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  ble_addr_t addr = { 0 };
  addr.type = address.address()[0];
  memcpy_reverse(addr.val, address.address() + 1, 6);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  auto device = _new BLERemoteDeviceResource(central_manager->group());
  if (!device) MALLOC_FAILED;

  err = ble_gap_connect(own_addr_type, &addr, 3000, NULL,
                        BLERemoteDeviceResource::on_event, device);
  if (err != ESP_OK) {
    delete device;
    return Primitive::os_error(err, process);
  }

  proxy->set_external_address(device);
  central_manager->group()->register_resource(device);
  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(BLERemoteDeviceResource, device);
  ble_gap_terminate(device->handle(),BLE_HS_EDONE);
  return process->program()->null_object();
}

PRIMITIVE(release_resource) {
  ARGS(Resource, resource);

  resource->resource_group()->unregister_resource(resource);

  return process->program()->null_object();
}

PRIMITIVE(discover_services) {
  ARGS(BLERemoteDeviceResource, device, Array, raw_service_uuids);

  if (raw_service_uuids->length() == 0) {
    int err = ble_gattc_disc_all_svcs(
        device->handle(),
        BLERemoteDeviceResource::on_service_discovered,
        device);
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
  } else if (raw_service_uuids->length() == 1) {
    Blob blob;
    Object* obj = raw_service_uuids->at(0);
    if (!obj->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS))
      WRONG_TYPE;
    ble_uuid_any_t uuid = uuid_from_blob(blob);
    int err = ble_gattc_disc_svc_by_uuid(
        device->handle(),
        &uuid.u,
        BLERemoteDeviceResource::on_service_discovered,
        device);
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
  } else INVALID_ARGUMENT;

  return process->program()->null_object();
}

PRIMITIVE(discover_services_result) {
  ARGS(BLERemoteDeviceResource, device);

  int count = 0;
  for (const auto &item: device->services()) {
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->program()->null_object());
  int idx = 0;
  for (const auto &item: device->services()) {
    Array* service_info = process->object_heap()->allocate_array(2, process->program()->null_object());
    if (service_info == null) ALLOCATION_FAILED;

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    Error* err = null;
    ByteArray* uuid_byte_array = byte_array_from_uuid(process, item->uuid(), &err);
    if (uuid_byte_array == null) return err;

    proxy->set_external_address(item);
    service_info->at_put(0, uuid_byte_array);
    service_info->at_put(1, proxy);
    array->at_put(idx++, service_info);
  }

  return array;
}

PRIMITIVE(discover_characteristics) {
  ARGS(BLEServiceResource, service, Array, raw_characteristics_uuids);

  if (raw_characteristics_uuids->length() == 0) {
    int err = ble_gattc_disc_all_chrs(service->device()->handle(),
                                      service->start_handle(),
                                      service->end_handle(),
                                      BLEServiceResource::on_characteristics_discover,
                                      service);
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
  } else if (raw_characteristics_uuids->length() == 1) {
    Blob blob;
    Object* obj = raw_characteristics_uuids->at(0);
    if (!obj->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS))
      WRONG_TYPE;
    ble_uuid_any_t uuid = uuid_from_blob(blob);
    int err = ble_gattc_disc_chrs_by_uuid(service->device()->handle(),
                                      service->start_handle(),
                                      service->end_handle(),
                                      &uuid.u,
                                      BLEServiceResource::on_characteristics_discover,
                                      service);
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
  } else INVALID_ARGUMENT;
  return process->program()->null_object();
}


PRIMITIVE(discover_characteristics_result) {
  ARGS(BLEServiceResource, service);

  int count = 0;
  for (const auto &item: service->characteristics()) {
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->program()->null_object());
  int idx = 0;
  for (const auto &characteristic: service->characteristics()) {
    Array* characteristic_data = process->object_heap()->allocate_array(
        3, process->program()->null_object());
    if (!characteristic_data) ALLOCATION_FAILED;

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    proxy->set_external_address(characteristic);
    array->at_put(idx++, characteristic_data);
    Error* err;
    ByteArray *uuid_byte_array = byte_array_from_uuid(process, characteristic->uuid(), &err);
    if (err) return err;
    characteristic_data->at_put(0, uuid_byte_array);
    characteristic_data->at_put(1, Smi::from(characteristic->properties()));
    characteristic_data->at_put(2, proxy);
  }

  return array;
}

PRIMITIVE(discover_descriptors) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(discover_descriptors_result) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(request_characteristic_read) {
  ARGS(BLECharacteristicResource, characteristic);

  ble_gattc_read(characteristic->service()->device()->handle(),
                 characteristic->value_handle(),
                 BLECharacteristicResource::on_attribute_read,
                 characteristic);

  return process->program()->null_object();
}

PRIMITIVE(get_characteristic_value) {
  ARGS(BLECharacteristicResource, characteristic);

  const os_mbuf* mbuf = characteristic->mbuf_received();
  if (!mbuf) return process->program()->null_object();
  Object* ret_val = convert_mbuf_to_heap_object(process, mbuf);
  if (!ret_val) ALLOCATION_FAILED;

  characteristic->set_mbuf_received(null);
  return ret_val;
}

PRIMITIVE(get_characteristic_error) {
  ARGS(BLECharacteristicResource, characteristic);
  if (characteristic->error() == 0) OTHER_ERROR;
  char err_text[20];
  sprintf(err_text, "Error: %d", characteristic->error());
  Error* err = null;
  String* message = process->allocate_string(err_text, &err);
  if (err) return err;

  characteristic->set_error(0);

  return message;
}

PRIMITIVE(advertise_start) {
  ARGS(BLEPeripheralManagerResource, peripheral_manager, Blob, name, Array, service_classes,
       Blob, manufacturing_data, int, interval_us, int, conn_mode);


  if (BLEPeripheralManagerResource::is_advertising()) ALREADY_EXISTS;


  struct ble_gap_adv_params adv_params = { 0 };
  adv_params.conn_mode = conn_mode;

  // TODO(anders): Be able to tune this.
  adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
  adv_params.itvl_min = adv_params.itvl_max = interval_us / 625;
  int err = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, null, BLE_HS_FOREVER, &adv_params, BLEEventSource::on_gap, group->gap());
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(advertise_config) {
  ARGS(BLEResourceGroup, group, Blob, name, Array, service_classes, Blob, custom_data);

  USE(service_classes);

  struct ble_hs_adv_fields fields = { 0 };
  if (name.length() > 0) {
    fields.name = name.address();
    fields.name_len = name.length();
    fields.name_is_complete = 1;
  }

  ble_uuid16_t uuids_16[service_classes->length()];
  ble_uuid32_t uuids_32[service_classes->length()];
  ble_uuid128_t uuids_128[service_classes->length()];
  for (int i = 0; i < service_classes->length(); i++) {
    Object* obj = service_classes->at(i);
    Blob blob;
    if (!obj->byte_content(process->program(), &blob, BlobKind::STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;

    ble_uuid_any_t uuid = uuid_from_blob(blob);
    if (uuid.u.type == BLE_UUID_TYPE_16) {
      uuids_16[fields.num_uuids16++] = uuid.u16;
    } else if (uuid.u.type == BLE_UUID_TYPE_32) {
      uuids_32[fields.num_uuids32++] = uuid.u32;
    } else {
      uuids_128[fields.num_uuids128++] = uuid.u128;
    }
  }
  fields.uuids16 = uuids_16;
  fields.uuids16_is_complete = 1;
  fields.uuids32 = uuids_32;
  fields.uuids32_is_complete = 1;
  fields.uuids128 = uuids_128;
  fields.uuids128_is_complete = 1;

  if (custom_data.length() > 0) {
    fields.mfg_data = custom_data.address();
    fields.mfg_data_len = custom_data.length();
  }

  int err = ble_gap_adv_set_fields(&fields);
  if (err != 0) {
    if (err == BLE_HS_EMSGSIZE) OUT_OF_RANGE;
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(advertise_stop) {
  ARGS(BLEResourceGroup, group);

  if (BLEPeripheralManagerResource::is_advertising()) {
    int err = ble_gap_adv_stop();
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
  }

  return process->program()->null_object();
}

PRIMITIVE(get_gatt) {
  ARGS(BLEResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  GATTResource* gatt = _new GATTResource(group);
  if (!gatt) MALLOC_FAILED;

  group->register_resource(gatt);
  proxy->set_external_address(gatt);

  return proxy;
}

PRIMITIVE(request_result) {
  ARGS(GATTResource, gatt);

  if (gatt->error() == BLE_HS_ENOENT) {
    OUT_OF_RANGE;
  } else if (gatt->error() != 0) {
    INVALID_ARGUMENT;
  }


  return Primitive::integer(gatt->result(), process);
}


PRIMITIVE(request_data) {
  ARGS(GATTResource, gatt);

  if (gatt->error() == BLE_HS_ENOENT) {
    OUT_OF_RANGE;
  } else if (gatt->error() != 0) {
    INVALID_ARGUMENT;
  }

  const os_mbuf* mbuf = gatt->mbuf();
  if (!mbuf) return process->program()->null_object();
  Object* ret_val = convert_mbuf_to_heap_object(process, mbuf);

  if (ret_val != null) {
    gatt->set_mbuf(null);
    return ret_val;
  } else {
    ALLOCATION_FAILED;
  }
}

PRIMITIVE(send_data) {
  ARGS(GATTResource, gatt, uint16, handle, Object, value);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  int err = ble_gattc_write(gatt->handle(), handle, om, NULL, NULL);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}


PRIMITIVE(request_attribute) {
  ARGS(GATTResource, gatt, uint16, handle);

  int err = ble_gattc_read(gatt->handle(), handle, BLEEventSource::on_gatt_attribute, gatt);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

/*
 *
 * Primitives for BLE server.
 *
 */
PRIMITIVE(server_configuration_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  // Mark usage. When the group is unregistered, the usage is automatically
  // decremented, but if group allocation fails, we manually call unuse().
  BLEEventSource* ble = BLEEventSource::instance();
  if (!ble->use()) {
    MALLOC_FAILED;
  }

  BLEServerConfigGroup* group = _new BLEServerConfigGroup(process, ble);
  if (!group) MALLOC_FAILED;

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(server_configuration_dispose) {
  ARGS(BLEServerConfigGroup, group);
  group->tear_down();
  return process->program()->null_object();
}

PRIMITIVE(add_server_service) {
  ARGS(BLEServerConfigGroup, group, Blob, uuid_blob);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  ble_uuid_any_t uuid = uuid_from_blob(uuid_blob);

  BLEServerServiceResource* service = group->add_service(uuid);
  if (!service) MALLOC_FAILED;

  proxy->set_external_address(service);
  return proxy;
}

PRIMITIVE(add_server_characteristic) {
  ARGS(BLEServerServiceResource, service, Blob, uuid_blob, int, type, Object, value);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  ble_uuid_any_t uuid = uuid_from_blob(uuid_blob);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  Mutex* resource_group_mutex = static_cast<BLEServerConfigGroup*>(service->resource_group())->mutex();

  BLEServerCharacteristicResource* characteristic =
      service->add_characteristic(uuid, type, om, resource_group_mutex);

  if (!characteristic) {
    if (om != null) os_mbuf_free(om);
    MALLOC_FAILED;
  }

  proxy->set_external_address(characteristic);
  return proxy;
}

PRIMITIVE(set_characteristics_value) {
  ARGS(BLEServerCharacteristicResource, resource, Object, value);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  resource->set_mbuf_to_send(om);

  return process->program()->null_object();
}

PRIMITIVE(notify_characteristics_value) {
  ARGS(BLEServerCharacteristicResource, resource, Object, value);

  if (resource->is_notify_enabled() || resource->is_indicate_enabled()) {
    os_mbuf* om = null;
    Object* error = object_to_mbuf(process, value, &om);
    if (error) return error;

    int err = ESP_OK;
    if (resource->is_notify_enabled()) {
      err = ble_gattc_notify_custom(resource->conn_handle(), resource->nimble_value_handle(), om);
    }

    if (err == ESP_OK && resource->is_indicate_enabled()) {
      err = ble_gattc_indicate_custom(resource->conn_handle(), resource->nimble_value_handle(), om);
    }

    if (err != ESP_OK) {
      if (om != null) os_mbuf_free(om);
      return Primitive::os_error(err, process);
    }
  }

  return BOOL(resource->is_notify_enabled());
}

PRIMITIVE(get_characteristics_value) {
  ARGS(BLEServerCharacteristicResource, resource);

  os_mbuf* mbuf = resource->mbuf_received();
  if (mbuf == null) return process->program()->null_object();

  Object* ret_val = convert_mbuf_to_heap_object(process, mbuf);

  if (ret_val != null) {
    resource->set_mbuf_received(null);
    return ret_val;
  } else {
    ALLOCATION_FAILED;
  }
}

PRIMITIVE(set_preferred_mtu) {
  ARGS(int, mtu);

  int result = ble_att_set_preferred_mtu(mtu);

  if (result) {
    INVALID_ARGUMENT;
  } else {
    return process->program()->null_object();
  }
}

PRIMITIVE(get_att_mtu) {
  ARGS(BLEServerCharacteristicResource, resource);

  uint16 mtu = ble_att_mtu(resource->conn_handle());

  return Smi::from(mtu);
}

} // namespace toit

#endif // TOIT_FREERTOS
