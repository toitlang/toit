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

#include "../resource.h"
#include "../objects_inline.h"
#include "../resource_pool.h"
#include "../scheduler.h"
#include "../vm.h"

#include "../event_sources/ble_esp32.h"

#include <esp_bt.h>
#include <esp_coexist.h>
#include <esp_nimble_hci.h>
#include <nimble/nimble_port.h>
#include <host/ble_hs.h>
#include <host/util/util.h>
#include <host/ble_gap.h>
#include <services/gap/ble_svc_gap.h>
#include <services/gatt/ble_svc_gatt.h>


namespace toit {

const int kInvalidBLE = -1;
const int kInvalidHandle = UINT16_MAX;

const int NO_CCCD_FOUND_FOR_CHARACTERISTIC = -20;
// Only allow one instance of BLE running.
ResourcePool<int, kInvalidBLE> ble_pool(
    0
);

class DiscoveredPeripheral;
typedef DoubleLinkedList<DiscoveredPeripheral> DiscoveredPeripheralList;

class DiscoveredPeripheral : public DiscoveredPeripheralList::Element {
 public:
  DiscoveredPeripheral(ble_addr_t addr, int8 rssi, uint8* data, uint8 data_length, uint8 event_type)
      : _addr(addr)
      , _rssi(rssi)
      , _data(data)
      , _data_length(data_length)
      , _event_type(event_type) {}

  ~DiscoveredPeripheral() {
    free(_data);
  }

  ble_addr_t addr() { return _addr; }
  int8 rssi() const { return _rssi; }
  uint8* data() { return _data; }
  uint8 data_length() const { return _data_length; }
  uint8 event_type() const { return _event_type; }
 private:
  ble_addr_t _addr;
  int8 _rssi;
  uint8* _data;
  uint8 _data_length;
  uint8 _event_type;
};


class BLEResourceGroup : public ResourceGroup, public Thread{
 public:
  TAG(BLEResourceGroup);
  BLEResourceGroup(Process* process, BLEEventSource* event_source, int id)
      : ResourceGroup(process, event_source)
      , Thread("BLE")
      , _id(id)
      , _sync(false) {
    if (instance_access_mutex()) { // Allocation of the mutex could fail, the init primitive reports this
      Locker locker(_instance_access_mutex);
      ASSERT(!_instance)
      _instance = this;
      spawn(CONFIG_NIMBLE_TASK_STACK_SIZE);
    }
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
  static Mutex* instance_access_mutex(bool allow_alloc=true) {
    if (!_instance_access_mutex && allow_alloc)
      _instance_access_mutex = OS::allocate_mutex(0,"BLE");
    return _instance_access_mutex;
  };

  void set_sync(bool sync) {
    for(Resource *resource : resources()) {
      auto ble_resource = reinterpret_cast<BLEResource*>(resource);
      BLEEventSource::instance()->on_event(ble_resource, kBLEStarted);
    }
  }

  bool sync() const { return _sync; }

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
Mutex* BLEResourceGroup::_instance_access_mutex = null;

class DiscoverableResource {
 public:
  DiscoverableResource() : _returned(false) {}
  bool is_returned() const { return _returned; }
  void set_returned(bool returned) { _returned = returned; }
 private:
  bool _returned;
};

class BLEErrorCapableResource: public BLEResource {
 public:
  BLEErrorCapableResource(ResourceGroup* group, Kind kind)
  : BLEResource(group, kind)
  , _malloc_error(false)
  , _error(0) {}

  bool has_malloc_error() const { return _malloc_error;}
  void set_malloc_error(bool malloc_error) { _malloc_error = malloc_error; }
  int error() const { return _error; }
  void set_error(int error) { _error = error; }
 private:
  bool _malloc_error;
  int _error;
};

class BLEServiceResource;

class BLEReadWriteElement : public BLEErrorCapableResource {
 public:
  BLEReadWriteElement(ResourceGroup* group, Kind kind, ble_uuid_any_t uuid, uint16 handle)
      : BLEErrorCapableResource(group,kind)
      , _uuid(uuid)
      , _handle(handle)
      , _mbuf_received(null)
      , _mbuf_to_send(null) {}
  ble_uuid_any_t &uuid() { return _uuid; }
  ble_uuid_t* ptr_uuid() { return &_uuid.u; }
  uint16 handle() const { return _handle; }
  uint16* ptr_handle() { return &_handle; }
  virtual BLEServiceResource* service() = 0;
  void set_mbuf_received(os_mbuf* mbuf)  {
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
    return _mbuf_received;
  }

  os_mbuf* mbuf_to_send() {
    Locker locker(BLEResourceGroup::instance_access_mutex());
    return _mbuf_to_send;
  }

  void set_mbuf_to_send(os_mbuf* mbuf) {
    Locker locker(BLEResourceGroup::instance_access_mutex());
    if (_mbuf_to_send != null) os_mbuf_free(_mbuf_to_send);
    _mbuf_to_send = mbuf;
  }

  static int on_attribute_read(uint16_t conn_handle,
                               const ble_gatt_error *error,
                               ble_gatt_attr *attr,
                               void *arg) {
    USE(conn_handle);
    unvoid_cast<BLEReadWriteElement*>(arg)->_on_attribute_read(error, attr);
    return BLE_ERR_SUCCESS;
  }

  static int on_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg) {
    USE(conn_handle);
    USE(attr_handle);
    return unvoid_cast<BLEReadWriteElement*>(arg)->_on_access(ctxt);
  }

 private:
  void _on_attribute_read(const ble_gatt_error *error, ble_gatt_attr *attr);
  int _on_access(ble_gatt_access_ctxt* ctxt);

  ble_uuid_any_t _uuid;
  uint16 _handle;
  os_mbuf* _mbuf_received;
  os_mbuf* _mbuf_to_send;

};


class BLEDescriptorResource;
typedef DoubleLinkedList<BLEDescriptorResource> DescriptorList;
class BLECharacteristicResource;

class BLEDescriptorResource: public BLEReadWriteElement, public DescriptorList::Element, public DiscoverableResource {
 public:
  TAG(BLEDescriptorResource);
  BLEDescriptorResource(ResourceGroup* group, BLECharacteristicResource *characteristic,
                        ble_uuid_any_t uuid, uint16 handle, int properties)
  : BLEReadWriteElement(group, DESCRIPTOR, uuid, handle)
  , _characteristic(characteristic)
  , _properties(properties) {}

  BLEServiceResource* service() override;
  uint8 properties() const { return _properties; }

 private:
  BLECharacteristicResource* _characteristic;
  uint8 _properties;
};

class Subscription;
typedef class DoubleLinkedList<Subscription> SubscriptionList;
class Subscription : public SubscriptionList::Element {
 public:
  Subscription(bool indication, bool notification, uint16 connHandle)
      : _indication(indication)
      , _notification(notification)
      , _conn_handle(connHandle) {}
  void set_indication(bool indication) { _indication = indication; }
  bool indication() const { return _indication; }
  void set_notification(bool notification) { _notification = notification; }
  bool notification() const { return _notification; }
  bool conn_handle() const { return _conn_handle; }

 private:
  bool _indication;
  bool _notification;
  uint16 _conn_handle;
};

typedef DoubleLinkedList<BLECharacteristicResource> CharacteristicResourceList;
class BLECharacteristicResource :
    public BLEReadWriteElement,
    public CharacteristicResourceList::Element,
    public DiscoverableResource {
 public:
  TAG(BLECharacteristicResource);
  BLECharacteristicResource(BLEResourceGroup* group, BLEServiceResource* service,
                            ble_uuid_any_t uuid, uint8 properties, uint16 handle,
                            uint16 definition_handle)
      : BLEReadWriteElement(group, CHARACTERISTIC, uuid, handle)
      , _service(service)
      , _properties(properties)
      , _definition_handle(definition_handle) {}

  ~BLECharacteristicResource() override {
    while (!_subscriptions.is_empty()) {
      free(_subscriptions.remove_first());
    }
  }

  BLEServiceResource* service() override { return _service; }

  uint8 properties() const { return _properties;  }
  uint16 definition_handle() const { return _definition_handle; }

  BLEDescriptorResource* get_or_create_descriptor(ble_uuid_any_t uuid, uint16_t handle,
                                                  uint8 properties, bool can_create=false);

  BLEDescriptorResource* find_descriptor(ble_uuid_any_t &uuid) {
    return get_or_create_descriptor(uuid, 0, false);
  }

  const BLEDescriptorResource* find_cccd_descriptor() {
    ble_uuid_any_t uuid;
    uuid.u16.u.type = BLE_UUID_TYPE_16;
    uuid.u16.value = BLE_GATT_DSC_CLT_CFG_UUID16;
    return find_descriptor(uuid);
  }

  DescriptorList& descriptors() {
    return _descriptors;
  }

  bool update_subscription_status(uint8_t indicate, uint8_t notify, uint16_t conn_handle);
  SubscriptionList& subscriptions() { return _subscriptions; }

  void make_deletable() override {
    while (!_descriptors.is_empty()) {
      group()->unregister_resource(_descriptors.remove_first());
    }
    BLEResource::make_deletable();
  }

  static int on_write_response(uint16_t conn_handle,
                               const ble_gatt_error* error,
                               ble_gatt_attr* attr,
                               void* arg) {
    USE(conn_handle);
    unvoid_cast<BLECharacteristicResource*>(arg)->_on_write_response(error, attr);
    return BLE_ERR_SUCCESS;
  }

  static int on_subscribe_response(uint16_t conn_handle,
                                  const ble_gatt_error* error,
                                  ble_gatt_attr* attr,
                                  void* arg) {
    USE(conn_handle);
    unvoid_cast<BLECharacteristicResource*>(arg)->_on_subscribe_response(error, attr);
    return BLE_ERR_SUCCESS;
  }

 private:
  void _on_write_response(const ble_gatt_error* error, ble_gatt_attr* attr);
  void _on_subscribe_response(const ble_gatt_error* error, ble_gatt_attr* attr);

  BLEServiceResource* _service;
  uint8 _properties;
  uint16 _definition_handle;
  DescriptorList _descriptors;
  SubscriptionList _subscriptions;
};

// Resources are already in two lists, so we add the arbitrary N template argument to distinguish from those two
typedef DoubleLinkedList<BLEServiceResource> ServiceResourceList;
class BLERemoteDeviceResource;
class BLEPeripheralManagerResource;

class BLEServiceResource:
    public BLEErrorCapableResource,
    public ServiceResourceList::Element,
    public DiscoverableResource {
 private:
  BLEServiceResource(BLEResourceGroup* group,
                     ble_uuid_any_t uuid, uint16 start_handle, uint16 end_handle)
      : BLEErrorCapableResource(group, SERVICE)
      , _uuid(uuid)
      , _start_handle(start_handle)
      , _end_handle(end_handle)
      , _deployed(false)
      , _characteristics_discovered(false)
      , _device(null)
      , _peripheral_manager(null) {}

 public:
  TAG(BLEServiceResource);
  BLEServiceResource(BLEResourceGroup* group, BLERemoteDeviceResource* device,
                     ble_uuid_any_t uuid, uint16 start_handle, uint16 end_handle)
      : BLEServiceResource(group, uuid, start_handle, end_handle) {
    _device = device;
  }

  BLEServiceResource(BLEResourceGroup* group, BLEPeripheralManagerResource* peripheral_manager,
                     ble_uuid_any_t uuid, uint16 start_handle, uint16 end_handle)
      : BLEServiceResource(group, uuid, start_handle, end_handle) {
    _peripheral_manager = peripheral_manager;
  }

  BLECharacteristicResource* get_or_create_characteristics_resource(
      ble_uuid_any_t uuid, uint8 properties, uint16 def_handle,
      uint16 value_handle, bool can_create=false);

  void make_deletable() override {
    while (!_characteristics.is_empty()) {
      group()->unregister_resource(_characteristics.remove_first());
    }
    BLEResource::make_deletable();
  }

  ble_uuid_any_t& uuid() { return _uuid; }
  ble_uuid_t* ptr_uuid() { return &_uuid.u; }
  uint16 start_handle() const { return _start_handle; }
  uint16 end_handle() const { return _end_handle; }

  BLERemoteDeviceResource* device() const { return _device;}
  BLEPeripheralManagerResource* peripheral_manager() const { return _peripheral_manager;}
  CharacteristicResourceList& characteristics() { return _characteristics; }
  void clear_characteristics() {
    while (!_characteristics.is_empty())
      group()->unregister_resource(_characteristics.remove_first());
  }
  bool deployed() const { return _deployed; }
  void set_deployed(bool deployed) { _deployed = deployed; }
  bool characteristics_discovered() const { return _characteristics_discovered; }
  void set_characteristics_discovered(bool discovered) { _characteristics_discovered = discovered; }

  static int on_characteristic_discovered(uint16_t conn_handle,
                                          const ble_gatt_error* error,
                                          const ble_gatt_chr* chr, void* arg) {
    USE(conn_handle);
    unvoid_cast<BLEServiceResource*>(arg)->_on_characteristic_discovered(error, chr);
    return BLE_ERR_SUCCESS;
  }

  static int on_descriptor_discovered(uint16_t conn_handle,
                                      const struct ble_gatt_error *error,
                                      uint16_t chr_val_handle,
                                      const struct ble_gatt_dsc *dsc,
                                      void *arg) {
    USE(conn_handle);
    unvoid_cast<BLEServiceResource*>(arg)->_on_descriptor_discovered(error, dsc, chr_val_handle, false);
    return BLE_ERR_SUCCESS;
  }


 private:
  void _on_characteristic_discovered(const ble_gatt_error *error, const ble_gatt_chr *chr);
  void _on_descriptor_discovered(const struct ble_gatt_error* error,
                                 const struct ble_gatt_dsc* dsc,
                                 uint16_t chr_val_handle,
                                 bool called_from_notify
  );

  CharacteristicResourceList _characteristics;
  ble_uuid_any_t _uuid;
  uint16 _start_handle;
  uint16 _end_handle;
  bool _deployed;
  bool _characteristics_discovered;
  BLERemoteDeviceResource *_device;
  BLEPeripheralManagerResource *_peripheral_manager;
};

class BLECentralManagerResource : public BLEErrorCapableResource {
 public:
  TAG(BLECentralManagerResource);

  explicit BLECentralManagerResource(BLEResourceGroup* group)
      : BLEErrorCapableResource(group, CENTRAL_MANAGER)
      , _mutex(OS::allocate_mutex(3, "")) {}

  ~BLECentralManagerResource() override {
    if (is_scanning()) {
      int err = ble_gap_disc_cancel();
      if (err != BLE_ERR_SUCCESS && err != BLE_HS_EALREADY) {
        fail("Failed to cancel discovery");
      }
    }

    while (auto peripheral = remove_discovered_peripheral()) {
      free(peripheral);
    }
  }

  static bool is_scanning() { return ble_gap_disc_active(); }

  DiscoveredPeripheral* get_discovered_peripheral() {
    return _newly_discovered_peripherals.first();
  }

  DiscoveredPeripheral* remove_discovered_peripheral() {
    return _newly_discovered_peripherals.remove_first();
  }

  static int on_discovery(ble_gap_event *event, void *arg) {
    unvoid_cast<BLECentralManagerResource*>(arg)->_on_discovery(event);
    return BLE_ERR_SUCCESS;
  };

  Mutex* mutex() { return _mutex; }
 private:
  void _on_discovery(ble_gap_event *event);
  DiscoveredPeripheralList _newly_discovered_peripherals;
  Mutex* _mutex;
};

template <typename T>
class ServiceContainer : public BLEErrorCapableResource {
 public:
  ServiceContainer(BLEResourceGroup* group, Kind kind)
      : BLEErrorCapableResource(group, kind) {}

  void make_deletable() override {
    clear_services();
    BLEResource::make_deletable();
  }


  virtual T* type() = 0;
  BLEServiceResource* get_or_create_service_resource(ble_uuid_any_t uuid, uint16 start, uint16 end, bool can_create=false);
  ServiceResourceList& services() { return _services; }
  void clear_services() {
    while (!_services.is_empty())
      group()->unregister_resource(_services.remove_first());
  }
 private:
  ServiceResourceList _services;
};


class BLEPeripheralManagerResource : public ServiceContainer<BLEPeripheralManagerResource> {
 public:
  TAG(BLEPeripheralManagerResource);
  explicit BLEPeripheralManagerResource(BLEResourceGroup* group)
  : ServiceContainer(group, PERIPHERAL_MANAGER)
  , _advertising_params({})
  , _advertising_started(false) {}

  ~BLEPeripheralManagerResource() override {
    if (is_advertising()) {
      FATAL_IF_NOT_ESP_OK(ble_gap_adv_stop());
    }
  }

  BLEPeripheralManagerResource* type() override { return this; }

  bool advertising_started() const { return _advertising_started; }
  void set_advertising_started(bool advertising_started)  { _advertising_started = advertising_started; }

  ble_gap_adv_params& advertising_params() { return _advertising_params; }

  static int on_gap(struct ble_gap_event *event, void *arg) {
    return unvoid_cast<BLEPeripheralManagerResource*>(arg)->_on_gap(event);
  }
  static bool is_advertising() { return ble_gap_adv_active(); }


 private:
  int _on_gap(struct ble_gap_event *event);
  ble_gap_adv_params _advertising_params;
  bool _advertising_started;
};

class BLERemoteDeviceResource : public ServiceContainer<BLERemoteDeviceResource> {
 public:
  TAG(BLERemoteDeviceResource);
  explicit BLERemoteDeviceResource(BLEResourceGroup* group)
    : ServiceContainer(group, REMOTE_DEVICE)
    , _handle(kInvalidHandle) {}

  BLERemoteDeviceResource* type() override { return this; }

  static int on_event(ble_gap_event *event, void *arg) {
    unvoid_cast<BLERemoteDeviceResource*>(arg)->_on_event(event);
    return BLE_ERR_SUCCESS;
  };

  static int on_service_discovered(uint16_t conn_handle,
                                   const struct ble_gatt_error *error,
                                   const struct ble_gatt_svc *service,
                                   void *arg) {
    unvoid_cast<BLERemoteDeviceResource*>(arg)->_on_service_discovered(error, service);
    return BLE_ERR_SUCCESS;
  }

  uint16 handle() const { return _handle; }
  void set_handle(uint16 handle) { _handle = handle; }
 private:
  void _on_event(ble_gap_event *event);
  void _on_service_discovered(const ble_gatt_error* error, const ble_gatt_svc* service);

  uint16 _handle;
};

Object* nimble_error_code_to_string(Process* process, int error_code, bool host) {
  static const size_t BUFFER_LEN = 400;
  char buffer[BUFFER_LEN];
  switch (error_code) { // NOLINT(hicpp-multiway-paths-covered)
    case NO_CCCD_FOUND_FOR_CHARACTERISTIC:
      break;
    default:
      const char* gist = "https://gist.github.com/mikkeldamsgaard/0857ce6a8b073a52d6f07973a441ad54";
      snprintf(buffer, BUFFER_LEN, "NimBLE error, Type: %s, error code: 0z%02x. See %s", host?"host":"client", error_code%0x100, gist);
      break;
  }
  String* str = process->allocate_string(buffer, static_cast<int>(strlen(buffer)));
  if (!str) ALLOCATION_FAILED;
  return Primitive::mark_as_error(str);
}

Object* nimle_stack_error(Process* process, int error_code) {
  return nimble_error_code_to_string(process, error_code, false);
}


static ble_uuid_any_t uuid_from_blob(Blob& blob) {
  ble_uuid_any_t uuid = {};
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
  return uuid;
}

static ByteArray* byte_array_from_uuid(Process* process, ble_uuid_any_t uuid, Error*& err) {
  err = null;

  ByteArray* byte_array = process->object_heap()->allocate_internal_byte_array(uuid.u.type/8);
  if (!byte_array) {
    err = Error::from(process->program()->allocation_failed());
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

static bool uuid_equals(ble_uuid_any_t& uuid, ble_uuid_any_t& other) {
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
  USE(resource);
  state |= data;
  return state;
}

BLEServiceResource* BLEDescriptorResource::service() {
  return _characteristic->service();
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

void
BLEServiceResource::_on_characteristic_discovered(const struct ble_gatt_error* error, const struct ble_gatt_chr* chr) {
  switch (error->status) {
    case 0: {
      auto ble_characteristic =
          get_or_create_characteristics_resource(
              chr->uuid, chr->properties, chr->def_handle,
              chr->val_handle, true);
      if (!ble_characteristic) {
        set_malloc_error(true);
      }
      break;
    }
    case BLE_HS_EDONE:
      if (has_malloc_error()) {
        clear_characteristics();
        BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
      } else {
        ble_gattc_disc_all_dscs(device()->handle(),
                                start_handle(),
                                end_handle(),
                                BLEServiceResource::on_descriptor_discovered,
                                this);
      }
      break;
    default:
      clear_characteristics();
      if (has_malloc_error()) {
        BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
      } else {
        set_error(error->status);
        BLEEventSource::instance()->on_event(this, kBLEDiscoverOperationFailed);
      }
      break;

  }
}

BLECharacteristicResource* BLEServiceResource::get_or_create_characteristics_resource(
    ble_uuid_any_t uuid, uint8 properties, uint16 def_handle,
    uint16 value_handle, bool can_create) {
  for (const auto &item: _characteristics) {
    if (uuid_equals(uuid, item->uuid())) return item;
  }
  if (!can_create) return null;

  auto characteristic = _new BLECharacteristicResource(group(), this, uuid, properties, value_handle, def_handle);
  if (!characteristic) return null;
  group()->register_resource(characteristic);
  _characteristics.append(characteristic);
  return characteristic;
}

void BLECentralManagerResource::_on_discovery(ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_DISC_COMPLETE:
      BLEEventSource::instance()->on_event(this, kBLECompleted);
      break;
    case BLE_GAP_EVENT_DISC: {
      uint8* data = null;
      uint8 data_length = 0;
      if (event->disc.length_data > 0) {
        data = unvoid_cast<uint8*>(malloc(event->disc.length_data));
        if (!data) {
          set_malloc_error(true);
          BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
          return;
        }
        memmove(data, event->disc.data, event->disc.length_data);
        data_length = event->disc.length_data;
      }

      auto discovered_peripheral
          = _new DiscoveredPeripheral(event->disc.addr, event->disc.rssi, data, data_length, event->disc.event_type);

      if (!discovered_peripheral) {
        if (data) free(data);
        set_malloc_error(true);
        BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
        return;
      }

      {
        Locker locker(_mutex);
        _newly_discovered_peripherals.append(discovered_peripheral);
      }

      BLEEventSource::instance()->on_event(this, kBLEDiscovery);
    }
  }
}

void BLERemoteDeviceResource::_on_event(ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (event->connect.status == 0) {
        ASSERT(handle() == kInvalidHandle)
        set_handle(event->connect.conn_handle);
        BLEEventSource::instance()->on_event(this, kBLEConnected);
        // TODO(mikkel): Expose this as a primitive
        ble_gattc_exchange_mtu(event->connect.conn_handle, null, null);
      } else {
        BLEEventSource::instance()->on_event(this, kBLEConnectFailed);
      }
      break;
    case BLE_GAP_EVENT_DISCONNECT:
      BLEEventSource::instance()->on_event(this, kBLEDisconnected);
      break;
    case BLE_GAP_EVENT_NOTIFY_RX:
      // Notify/indicate update

      // TODO(mikkel): More efficient data structure
      for (const auto &service: services()) {
        for (const auto &characteristic: service->characteristics()) {
          if (characteristic->handle() == event->notify_rx.attr_handle) {
            {
              Locker locker(BLEResourceGroup::instance_access_mutex());
              characteristic->set_mbuf_received(event->notify_rx.om);
            }
            event->notify_rx.om = null;
            BLEEventSource::instance()->on_event(characteristic, kBLEValueDataReady);
            return;
          }
        }
      }
      break;
  }
}

void BLERemoteDeviceResource::_on_service_discovered(const ble_gatt_error* error, const ble_gatt_svc* service) {
  switch (error->status) {
    case 0: {
      auto ble_service = get_or_create_service_resource(service->uuid, service->start_handle, service->end_handle, true);
      if (!ble_service) {
        set_malloc_error(true);
      }
      break;
    }
    case BLE_HS_EDONE:
      if (has_malloc_error()) {
        clear_services();
        BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
      } else {
        BLEEventSource::instance()->on_event(this, kBLEServicesDiscovered);
      }
      break;
    default:
      clear_services();
      if (has_malloc_error()) {
        BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
      } else {
        set_error(error->status);
        BLEEventSource::instance()->on_event(this, kBLEDiscoverOperationFailed);
      }
      break;
  }
}

BLEDescriptorResource* BLECharacteristicResource::get_or_create_descriptor(
    ble_uuid_any_t uuid, uint16_t handle, uint8 properties, bool can_create) {
  for (const auto &descriptor: _descriptors) {
    if (uuid_equals(uuid, descriptor->uuid())) return descriptor;
  }
  if (!can_create) return null;

  auto descriptor = _new BLEDescriptorResource(group(), this, uuid, handle, properties);
  if (!descriptor) return null;
  group()->register_resource(descriptor);
  _descriptors.append(descriptor);
  return descriptor;
}

void BLEReadWriteElement::_on_attribute_read(
    const struct ble_gatt_error* error,
    struct ble_gatt_attr* attr) {
  switch (error->status) {
    case 0: {
      {
        Locker locker(BLEResourceGroup::instance_access_mutex());
        set_mbuf_received(attr->om);
      }
      // Take ownership of the buffer.
      attr->om = null;
      BLEEventSource::instance()->on_event(this, kBLEValueDataReady);
      break;
    }
    case BLE_HS_EDONE:
      break;

    default:
      set_error(error->status);
      BLEEventSource::instance()->on_event(this, kBLEValueDataReadFailed);
      break;
  }
}

int BLEReadWriteElement::_on_access(ble_gatt_access_ctxt* ctxt) {
  switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
    case BLE_GATT_ACCESS_OP_READ_DSC:
      if (mbuf_to_send() != null) {
        return os_mbuf_appendfrom(ctxt->om, mbuf_to_send(), 0, mbuf_to_send()->om_len);
      }
      break;
    case BLE_GATT_ACCESS_OP_WRITE_CHR:
    case BLE_GATT_ACCESS_OP_WRITE_DSC:
      {
        Locker locker(BLEResourceGroup::instance_access_mutex());
        set_mbuf_received(ctxt->om);
      }
      ctxt->om = null;
      BLEEventSource::instance()->on_event(this, kBLEDataReceived);
      break;
    default:
      // Unhandled event, no dispatching.
      return 0;
  }
  return BLE_ERR_SUCCESS;
}

void BLECharacteristicResource::_on_write_response(
    const struct ble_gatt_error* error,
    struct ble_gatt_attr* attr) {
  USE(attr);
  switch (error->status & 0xFF) {
    case 0:
    case BLE_HS_EDONE:
      BLEEventSource::instance()->on_event(this, kBLEValueWriteSucceeded);
      break;
    default:
      set_error(error->status);
      BLEEventSource::instance()->on_event(this, kBLEValueWriteFailed);
      break;
  }
}

void BLECharacteristicResource::_on_subscribe_response(
    const struct ble_gatt_error* error,
    struct ble_gatt_attr* attr) {
  USE(attr);
  switch (error->status) {
    case 0:
    case BLE_HS_EDONE:
      BLEEventSource::instance()->on_event(this, kBLESubscriptionOperationSucceeded);
      break;
    default:
      set_error(error->status);
      BLEEventSource::instance()->on_event(this, kBLESubscriptionOperationFailed);
      break;
  }
}

void
BLEServiceResource::_on_descriptor_discovered(const struct ble_gatt_error* error, const struct ble_gatt_dsc* dsc,
                                                     uint16_t chr_val_handle, bool called_from_notify) {
  switch (error->status) {
    case 0: {
      // Find the characteristic
      BLECharacteristicResource* characteristic = null;

      for (const auto &current: _characteristics) {
        if (!characteristic) {
          if (dsc->handle <= start_handle()) return;
        } else {
          if (characteristic->definition_handle() <= dsc->handle && dsc->handle <= characteristic->handle()) return;
          if (characteristic->handle() < dsc->handle && dsc->handle < current->definition_handle()) break;
        }
        characteristic = current;
      }
      if (dsc->handle <= characteristic->handle()) return;
      auto descriptor = characteristic->get_or_create_descriptor(dsc->uuid, dsc->handle,0, true);
      if (!descriptor) {
        set_malloc_error(true);
      }
      break;
    }

    case BLE_HS_EDONE:
      if (has_malloc_error()) {
        BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
      } else {
        set_characteristics_discovered(true);
        BLEEventSource::instance()->on_event(this, kBLECharacteristicsDiscovered);
      }
      break;

    default:
      if (has_malloc_error()) {
        BLEEventSource::instance()->on_event(this, kBLEMallocFailed);
      } else {
        set_error(error->status);
        if (called_from_notify) {
          BLEEventSource::instance()->on_event(this, kBLESubscriptionOperationFailed);
        } else {
          BLEEventSource::instance()->on_event(this, kBLEDescriptorsDiscovered);
        }
        break;
      }
  }
}

bool BLECharacteristicResource::update_subscription_status(uint8_t indicate, uint8_t notify, uint16_t conn_handle) {
  for (const auto &subscription: _subscriptions) {
    if (subscription->conn_handle() == conn_handle) {
      if (!indicate && !notify) {
        _subscriptions.unlink(subscription);
        free(subscription);
        return true;
      } else {
        subscription->set_indication(indicate);
        subscription->set_notification(notify);
        return true;
      }
    }
  }

  auto subscription = _new Subscription(indicate,notify,conn_handle);
  if (!subscription) {
    // Since this method is called from the BLE event handler and there is no
    // toit code monitoring the interaction, we resort to calling gc by hand to
    // try to recover on OOM.
    VM::current()->scheduler()->gc(null, /* malloc_failed = */ true, /* try_hard = */ true);
    subscription = _new Subscription(indicate,notify,conn_handle);
    if (!subscription) return false;
  }

  _subscriptions.append(subscription);
  return true;
}

int BLEPeripheralManagerResource::_on_gap(struct ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (advertising_started()) {
        // NimBLE stops advertising on connection event. To keep the library consistent
        // with other platforms the advertising is restarted
        int err = ble_gap_adv_start(
            BLE_OWN_ADDR_PUBLIC,
            null,
            BLE_HS_FOREVER,
            &advertising_params(),
            BLEPeripheralManagerResource::on_gap,
            this);
        if (err != BLE_ERR_SUCCESS) {
          ESP_LOGW("BLE", "Could not restart advertising: err=%d",err);
        }
      }
      break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
      // TODO(mikkel) Add stopped event
      //BLEEventSource::instance()->on_event(this, kBLEAdvertiseStopped);
      break;
    case BLE_GAP_EVENT_SUBSCRIBE: {
      for (auto service: services()) {
        for (auto characteristic: service->characteristics()) {
          if (characteristic->handle() == event->subscribe.attr_handle) {
            bool success = characteristic->update_subscription_status(
                event->subscribe.cur_indicate,
                event->subscribe.cur_notify,
                event->subscribe.conn_handle);

            return success?BLE_ERR_SUCCESS:BLE_ERR_MEM_CAPACITY;
          }
        }
      }
    }
  }
  return BLE_ERR_SUCCESS;

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
    FATAL("error setting address; rc=%d", rc)
  }
  {
    Locker locker(BLEResourceGroup::instance_access_mutex());

    BLEResourceGroup* instance = BLEResourceGroup::instance();
    if (instance) {
      instance->set_sync(true);
      ble_gatts_reset();
    }
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
  if (err != BLE_ERR_SUCCESS) {
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
  if (!group || !BLEResourceGroup::instance_access_mutex(false)) {
    ble->unuse();
    ble_pool.put(id);
    MALLOC_FAILED;
  }

  ble_hs_cfg.sync_cb = ble_on_sync;

  nimble_port_init();

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create_central_manager) {
  ARGS(BLEResourceGroup, group)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto central_manager = _new BLECentralManagerResource(group);
  if (!central_manager) MALLOC_FAILED;

  group->register_resource(central_manager);
  proxy->set_external_address(central_manager);

  {
    Locker locker(BLEResourceGroup::instance_access_mutex());
    if (group->sync()) BLEEventSource::instance()->on_event(central_manager, kBLEStarted);
  }

  return proxy;
}

PRIMITIVE(create_peripheral_manager) {
  ARGS(BLEResourceGroup, group)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto peripheral_manager = _new BLEPeripheralManagerResource(group);
  if (!peripheral_manager) MALLOC_FAILED;

  ble_svc_gap_init();
  ble_svc_gatt_init();

  group->register_resource(peripheral_manager);
  proxy->set_external_address(peripheral_manager);

  {
    Locker locker(BLEResourceGroup::instance_access_mutex());
    if (group->sync()) {
      ble_gatts_reset();
      BLEEventSource::instance()->on_event(peripheral_manager, kBLEStarted);
    }
  }

  return proxy;
}

PRIMITIVE(close) {
  ARGS(BLEResourceGroup, group)
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(scan_start) {
  ARGS(BLECentralManagerResource, central_manager, int64, duration_us)

  if (BLECentralManagerResource::is_scanning()) ALREADY_EXISTS;

  int32 duration_ms = duration_us < 0 ? BLE_HS_FOREVER : static_cast<int>(duration_us / 1000);

  uint8_t own_addr_type;

  /* Figure out address to use while advertising (no privacy for now) */
  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != BLE_ERR_SUCCESS) {
    return nimle_stack_error(process,err);
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

  if (err != BLE_ERR_SUCCESS) {
    return nimle_stack_error(process,err);
  }

  return process->program()->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BLECentralManagerResource, central_manager)
  Locker locker(central_manager->mutex());

  DiscoveredPeripheral* next = central_manager->get_discovered_peripheral();
  if (!next) return process->program()->null_object();

  Array* array = process->object_heap()->allocate_array(6, process->program()->null_object());
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
        String* name = process->allocate_string((const char*)fields.name, fields.name_len);
        if (!name) ALLOCATION_FAILED;
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

      if (fields.mfg_data_len > 0 && fields.mfg_data) {
        ByteArray* custom_data = process->object_heap()->allocate_internal_byte_array(fields.mfg_data_len);
        if (!custom_data) ALLOCATION_FAILED;
        ByteArray::Bytes custom_data_bytes(custom_data);
        memcpy(custom_data_bytes.address(), fields.mfg_data, fields.mfg_data_len);
        array->at_put(4, custom_data);
      }
    }

    array->at_put(5, BOOL(next->event_type() == BLE_HCI_ADV_RPT_EVTYPE_ADV_IND ||
                          next->event_type() == BLE_HCI_ADV_RPT_EVTYPE_DIR_IND));
  }

  central_manager->remove_discovered_peripheral();

  free(next);

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(Resource, resource)

  if (BLECentralManagerResource::is_scanning()) {
    int err = ble_gap_disc_cancel();
    if (err != BLE_ERR_SUCCESS) {
      return nimle_stack_error(process,err);
    }
    // If ble_gap_disc_cancel returns without an error, the discovery has stopped and NimBLE will not provide an
    // event. So we fire the event manually.
    BLEEventSource::instance()->on_event(reinterpret_cast<BLEResource*>(resource), kBLECompleted);
  }

  return process->program()->null_object();
}

PRIMITIVE(connect) {
  ARGS(BLECentralManagerResource, central_manager, Blob, address)

  uint8_t own_addr_type;

  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != BLE_ERR_SUCCESS) {
    return nimle_stack_error(process,err);
  }

  ble_addr_t addr = { 0 };
  addr.type = address.address()[0];
  memcpy_reverse(addr.val, address.address() + 1, 6);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  auto device = _new BLERemoteDeviceResource(central_manager->group());
  if (!device) MALLOC_FAILED;

  err = ble_gap_connect(own_addr_type, &addr, 3000, null,
                        BLERemoteDeviceResource::on_event, device);
  if (err != BLE_ERR_SUCCESS) {
    delete device;
    return nimle_stack_error(process,err);
  }

  proxy->set_external_address(device);
  central_manager->group()->register_resource(device);
  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(BLERemoteDeviceResource, device)
  ble_gap_terminate(device->handle(),BLE_ERR_REM_USER_CONN_TERM);
  return process->program()->null_object();
}

PRIMITIVE(release_resource) {
  ARGS(Resource, resource)
  resource->resource_group()->unregister_resource(resource);

  return process->program()->null_object();
}

PRIMITIVE(discover_services) {
  ARGS(BLERemoteDeviceResource, device, Array, raw_service_uuids)

  if (raw_service_uuids->length() == 0) {
    int err = ble_gattc_disc_all_svcs(
        device->handle(),
        BLERemoteDeviceResource::on_service_discovered,
        device);
    if (err != BLE_ERR_SUCCESS) {
      return nimle_stack_error(process,err);
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
    if (err != BLE_ERR_SUCCESS) {
      return nimle_stack_error(process,err);
    }
  } else INVALID_ARGUMENT;

  return process->program()->null_object();
}

PRIMITIVE(discover_services_result) {
  ARGS(BLERemoteDeviceResource, device)

  int count = 0;
  for (const auto &service: device->services()) {
    if (service->is_returned()) continue;
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  int idx = 0;
  for (const auto &service: device->services()) {
    if (service->is_returned()) continue;

    Array* service_info = process->object_heap()->allocate_array(2, process->program()->null_object());
    if (service_info == null) ALLOCATION_FAILED;

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    Error* err = null;
    ByteArray* uuid_byte_array = byte_array_from_uuid(process, service->uuid(), err);
    if (uuid_byte_array == null) return err;

    proxy->set_external_address(service);
    service_info->at_put(0, uuid_byte_array);
    service_info->at_put(1, proxy);
    array->at_put(idx++, service_info);
  }

  for (const auto &service: device->services()) service->set_returned(true);

  return array;
}

PRIMITIVE(discover_characteristics){
  ARGS(BLEServiceResource, service, Array, raw_characteristics_uuids)
  // Nimble has a funny thing about descriptors (needed to subscriptions), so that all characteristics
  // needs to be discovered to discover descriptors. Therefore, we ignore the raw_characteristics_uuids
  // and always discover all, if they haven't been discovered yet.
  USE(raw_characteristics_uuids);
  if (!service->characteristics_discovered()) {
    int err = ble_gattc_disc_all_chrs(service->device()->handle(),
                                          service->start_handle(),
                                          service->end_handle(),
                                          BLEServiceResource::on_characteristic_discovered,
                                          service);
    if (err != BLE_ERR_SUCCESS) {
      return nimle_stack_error(process,err);
    }
  } else {
    BLEEventSource::instance()->on_event(service, kBLECharacteristicsDiscovered);
  }

  return process->program()->null_object();
}

PRIMITIVE(discover_characteristics_result) {
  ARGS(BLEServiceResource, service)

  int count = 0;
  for (const auto &characteristic: service->characteristics()) {
    if (characteristic->is_returned()) continue;
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  int idx = 0;
  for (const auto &characteristic: service->characteristics()) {
    if (characteristic->is_returned()) continue;

    Array* characteristic_data = process->object_heap()->allocate_array(
        3, process->program()->null_object());
    if (!characteristic_data) ALLOCATION_FAILED;

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    proxy->set_external_address(characteristic);
    array->at_put(idx++, characteristic_data);
    Error* err;
    ByteArray *uuid_byte_array = byte_array_from_uuid(process, characteristic->uuid(), err);
    if (err) return err;
    characteristic_data->at_put(0, uuid_byte_array);
    characteristic_data->at_put(1, Smi::from(characteristic->properties()));
    characteristic_data->at_put(2, proxy);

    characteristic->set_returned(true);
  }

  return array;
}

PRIMITIVE(discover_descriptors) {
  ARGS(BLECharacteristicResource, characteristic)
  // We always discover descriptors when discovering characteristics
  BLEEventSource::instance()->on_event(characteristic, kBLEDescriptorsDiscovered);

  return process->program()->null_object();
}

PRIMITIVE(discover_descriptors_result) {
  ARGS(BLECharacteristicResource, characteristic)

  int count = 0;
  for (const auto &descriptor: characteristic->descriptors()) {
    if (descriptor->is_returned()) continue;
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  int idx = 0;
  for (const auto &descriptor: characteristic->descriptors()) {
    if (descriptor->is_returned()) continue;

    Array* descriptor_result = process->object_heap()->allocate_array(2, process->program()->null_object());

    Error* err;
    ByteArray *uuid_byte_array = byte_array_from_uuid(process, descriptor->uuid(), err);
    if (err) return err;

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) ALLOCATION_FAILED;

    proxy->set_external_address(descriptor);

    descriptor_result->at_put(0, uuid_byte_array);
    descriptor_result->at_put(1, proxy);
    array->at_put(idx++, descriptor_result);

    descriptor->set_returned(true);
  }

  return array;
}

PRIMITIVE(request_read) {
  ARGS(Resource, resource)

  auto element = reinterpret_cast<BLEReadWriteElement*>(resource);

  if (!element->service()->device()) INVALID_ARGUMENT;

  ble_gattc_read_long(element->service()->device()->handle(),
                 element->handle(),
                 0,
                 BLEReadWriteElement::on_attribute_read,
                 element);

  return process->program()->null_object();
}

PRIMITIVE(get_value) {
  ARGS(Resource, resource)
  Locker locker(BLEResourceGroup::instance_access_mutex());

  auto element = reinterpret_cast<BLEReadWriteElement*>(resource);

  const os_mbuf* mbuf = element->mbuf_received();
  if (!mbuf) return process->program()->null_object();

  Object* ret_val = convert_mbuf_to_heap_object(process, mbuf);
  if (!ret_val) ALLOCATION_FAILED;

  element->set_mbuf_received(null);
  return ret_val;
}

PRIMITIVE(write_value) {
  ARGS(Resource, resource, Object, value, bool, with_response)

  auto element = reinterpret_cast<BLEReadWriteElement*>(resource);

  if (!element->service()->device()) INVALID_ARGUMENT;

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  int err;
  if (with_response) {
    err = ble_gattc_write_long(
        element->service()->device()->handle(),
        element->handle(),
        0,
        om,
        BLECharacteristicResource::on_write_response,
        element);
  } else {
    err = ble_gattc_write_no_rsp(
        element->service()->device()->handle(),
        element->handle(),
        om
    );
  }

  if (err != BLE_ERR_SUCCESS) {
    return nimle_stack_error(process,err);
  }

  return Smi::from(with_response ? 1 : 0);
}

/* Enables or disables notifications/indications for the characteristic value
 * of $characteristic. If $characteristic allows both, notifications will be used.
*/
PRIMITIVE(set_characteristic_notify) {
  ARGS(BLECharacteristicResource, characteristic, bool, enable)
  uint16 value = 0;

  if (enable) {
    if (characteristic->properties() & BLE_GATT_CHR_F_NOTIFY) {
      value = 1;
    } else if (characteristic->properties() & BLE_GATT_CHR_F_INDICATE) {
      value = 2;
    }
  }

  auto cccd = characteristic->find_cccd_descriptor();
  if (!cccd) {
    INVALID_ARGUMENT;
  } else {
    int err = ble_gattc_write_flat(
        characteristic->service()->device()->handle(),
        cccd->handle(),
        static_cast<void*>(&value), 2,
        BLECharacteristicResource::on_subscribe_response,
        characteristic);

    if (err != BLE_ERR_SUCCESS) {
      return nimle_stack_error(process,err);
    }
  }

  return process->program()->null_object();
}

PRIMITIVE(advertise_start) {
  ARGS(BLEPeripheralManagerResource, peripheral_manager, Blob, name, Array, service_classes,
       Blob, manufacturing_data, int, interval_us, int, conn_mode)

  if (BLEPeripheralManagerResource::is_advertising()) ALREADY_EXISTS;

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

  if (manufacturing_data.length() > 0) {
    fields.mfg_data = manufacturing_data.address();
    fields.mfg_data_len = manufacturing_data.length();
  }

  int err = ble_gap_adv_set_fields(&fields);
  if (err != BLE_ERR_SUCCESS) {
    if (err == BLE_HS_EMSGSIZE) OUT_OF_RANGE;
    return nimle_stack_error(process,err);
  }

  peripheral_manager->advertising_params().conn_mode = conn_mode;

  // TODO(anders): Be able to tune this.
  peripheral_manager->advertising_params().disc_mode = BLE_GAP_DISC_MODE_GEN;
  peripheral_manager->advertising_params().itvl_min =
      peripheral_manager->advertising_params().itvl_max =
          interval_us / 625;
  err = ble_gap_adv_start(
      BLE_OWN_ADDR_PUBLIC,
      null,
      BLE_HS_FOREVER,
      &peripheral_manager->advertising_params(),
      BLEPeripheralManagerResource::on_gap,
      peripheral_manager);
  if (err != BLE_ERR_SUCCESS) {
    return nimle_stack_error(process,err);
  }
  peripheral_manager->set_advertising_started(true);
  // nimnle does not provide a advertise started gap event, so we just simulate the event
  // from the primitive
  BLEEventSource::instance()->on_event(peripheral_manager, kBLEAdvertiseStartSucceeded);
  return process->program()->null_object();
}

PRIMITIVE(advertise_stop) {
  ARGS(BLEPeripheralManagerResource, peripheral_manager);
  if (BLEPeripheralManagerResource::is_advertising()) {
    int err = ble_gap_adv_stop();
    if (err != BLE_ERR_SUCCESS) {
      return nimle_stack_error(process,err);
    }
  }
  peripheral_manager->set_advertising_started(false);

  return process->program()->null_object();
}

PRIMITIVE(add_service) {
  ARGS(BLEPeripheralManagerResource, peripheral_manager, Blob, uuid)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
  ble_uuid_any_t ble_uuid = uuid_from_blob(uuid);

  BLEServiceResource* service_resource =
      peripheral_manager->get_or_create_service_resource(ble_uuid, 0,0, true);
  if (!service_resource) MALLOC_FAILED;
  if (service_resource->deployed()) INVALID_ARGUMENT;

  proxy->set_external_address(service_resource);
  return proxy;
}

PRIMITIVE(add_characteristic) {
  ARGS(BLEServiceResource, service_resource, Blob, raw_uuid, int, properties, int, permissions, Object, value)

  if (!service_resource->peripheral_manager()) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (service_resource->deployed()) INVALID_ARGUMENT;

  ble_uuid_any_t ble_uuid = uuid_from_blob(raw_uuid);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  uint32 flags = properties & 0x7F;
  if (permissions & 0x1) flags |= BLE_GATT_CHR_F_READ;
  if (permissions & 0x2 && !(properties & (BLE_GATT_CHR_PROP_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP)))
    INVALID_ARGUMENT;
  if (permissions & 0x4) flags |= BLE_GATT_CHR_F_READ_ENC;
  if (permissions & 0x8) flags |= BLE_GATT_CHR_F_WRITE_ENC;

  BLECharacteristicResource* characteristic =
    service_resource->get_or_create_characteristics_resource(
        ble_uuid, flags,0,0,true);

  if (!characteristic) {
    if (om != null) os_mbuf_free(om);
    MALLOC_FAILED;
  }

  if (om != null)
    characteristic->set_mbuf_to_send(om);

  proxy->set_external_address(characteristic);
  return proxy;
}

PRIMITIVE(add_descriptor) {
  ARGS(BLECharacteristicResource, characteristic, Blob, raw_uuid, Object, value, int, properties, int, permissions)

  if (!characteristic->service()->peripheral_manager()) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  ble_uuid_any_t ble_uuid = uuid_from_blob(raw_uuid);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  uint8 flags = 0;
  if (properties & BLE_GATT_CHR_F_READ || permissions & 0x01) flags |= BLE_ATT_F_READ;
  if (properties & (BLE_GATT_CHR_F_WRITE & BLE_GATT_CHR_F_WRITE_NO_RSP) || permissions & 0x02) flags |= BLE_ATT_F_WRITE;
  if (permissions & 0x04) flags |= BLE_ATT_F_READ_ENC;
  if (permissions & 0x08) flags |= BLE_ATT_F_WRITE_ENC;

  BLEDescriptorResource* descriptor =
      characteristic->get_or_create_descriptor(ble_uuid, 0, flags, true);
  if (!descriptor) {
    if (om != null) os_mbuf_free(om);
    MALLOC_FAILED;
  }

  if (om != null)
    descriptor->set_mbuf_to_send(om);

  proxy->set_external_address(descriptor);
  return proxy;
}

void clean_up_gatt_svr_chars(ble_gatt_chr_def* gatt_svr_chars, int count) {
  for (int i=0;i<count;i++) {
    if (gatt_svr_chars[i].descriptors) free(gatt_svr_chars[i].descriptors);
  }
  free(gatt_svr_chars);
}

PRIMITIVE(deploy_service) {
  ARGS(BLEServiceResource, service_resource)

  if (!service_resource->peripheral_manager()) INVALID_ARGUMENT;
  if (service_resource->deployed()) INVALID_ARGUMENT;

  int characteristic_cnt = 0;
  for (const auto &i: service_resource->characteristics()) {
    USE(i);
    characteristic_cnt++;
  }

  auto gatt_svr_chars = static_cast<ble_gatt_chr_def*>(
      calloc(characteristic_cnt + 1, sizeof(ble_gatt_chr_def)));
  if (!gatt_svr_chars) MALLOC_FAILED;

  int characteristic_idx = 0;
  for (BLECharacteristicResource* characteristic: service_resource->characteristics()) {
    gatt_svr_chars[characteristic_idx].uuid = characteristic->ptr_uuid();
    gatt_svr_chars[characteristic_idx].access_cb = BLEReadWriteElement::on_access;
    gatt_svr_chars[characteristic_idx].arg = characteristic;
    gatt_svr_chars[characteristic_idx].val_handle = characteristic->ptr_handle();
    gatt_svr_chars[characteristic_idx].flags = characteristic->properties();

    int descriptor_cnt = 0;
    for (const auto &item: characteristic->descriptors()) {
      USE(item);
      descriptor_cnt++;
    }

    if (descriptor_cnt>0) {
      auto gatt_desc_defs = static_cast<ble_gatt_dsc_def*>(
          calloc(descriptor_cnt+1,sizeof(ble_gatt_dsc_def)));

      if (!gatt_desc_defs) {
        clean_up_gatt_svr_chars(gatt_svr_chars,characteristic_idx);
        MALLOC_FAILED;
      }


      int descriptor_idx = 0;
      for (const auto &descriptor: characteristic->descriptors()) {
        gatt_desc_defs[descriptor_idx].uuid = descriptor->ptr_uuid();
        gatt_desc_defs[descriptor_idx].att_flags = descriptor->properties();
        gatt_desc_defs[descriptor_idx].access_cb = BLEReadWriteElement::on_access;
        gatt_desc_defs[descriptor_idx].arg = descriptor;
      }
    }
    characteristic_idx++;
  }

  auto gatt_services = static_cast<ble_gatt_svc_def*>(calloc(2, sizeof(ble_gatt_svc_def)));
  if (!gatt_services) {
    clean_up_gatt_svr_chars(gatt_svr_chars,characteristic_cnt);
    free(gatt_svr_chars);
    MALLOC_FAILED;
  }

  gatt_services[1].type = 0;
  gatt_services[0].type = BLE_GATT_SVC_TYPE_PRIMARY;
  gatt_services[0].uuid = service_resource->ptr_uuid();
  gatt_services[0].characteristics = gatt_svr_chars;

  int rc = ble_gatts_count_cfg(gatt_services);
  if (rc == BLE_ERR_SUCCESS) rc = ble_gatts_add_svcs(gatt_services);
  if (rc == BLE_ERR_SUCCESS) rc = ble_gatts_start();
  if (rc != BLE_ERR_SUCCESS) {
    free(gatt_services);
    free(gatt_svr_chars);
    return nimle_stack_error(process, rc);
  }

  // nimble does not do async service deployments, so
  // simulate success event
  BLEEventSource::instance()->on_event(service_resource, kBLEServiceAddSucceeded);
  service_resource->set_deployed(true);
  return process->program()->null_object();
}

PRIMITIVE(set_value) {
  ARGS(Resource, resource, Object, value)

  auto element = reinterpret_cast<BLEReadWriteElement*>(resource);

  if (!element->service()->peripheral_manager()) INVALID_ARGUMENT;

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  element->set_mbuf_to_send(om);

  return process->program()->null_object();
}

PRIMITIVE(get_subscribed_clients) {
  ARGS(BLECharacteristicResource, characteristic)
  int cnt = 0;
  for (const auto &item: characteristic->subscriptions()) {
    USE(item);
    cnt++;
  }

  Array* array = process->object_heap()->allocate_array(cnt, process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  int idx = 0;
  for (const auto &sub: characteristic->subscriptions()) {
    array->at_put(idx++, Smi::from(sub->conn_handle()));
  }

  return array;
}

PRIMITIVE(notify_characteristics_value) {
  ARGS(BLECharacteristicResource, characteristic, uint16, conn_handle, Object, value)

  Subscription* subscription = null;
  for (const auto &sub: characteristic->subscriptions()) {
    if (sub->conn_handle() == conn_handle) {
      subscription = sub;
    }
  }

  if (!subscription) INVALID_ARGUMENT;

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  int err = BLE_ERR_SUCCESS;
  if (subscription->notification()) {
    err = ble_gattc_notify_custom(subscription->conn_handle(), characteristic->handle(), om);
  } else if (subscription->indication()) {
    err = ble_gattc_indicate_custom(subscription->conn_handle(), characteristic->handle(), om);
  }

  if (err != BLE_ERR_SUCCESS) {
    return nimle_stack_error(process, err);
  }

  return process->program()->null_object();
}

PRIMITIVE(get_att_mtu) {
  ARGS(Resource, resource)

  auto ble_resource = reinterpret_cast<BLEResource*>(resource);

  uint16 mtu = BLE_ATT_MTU_DFLT;
  switch (ble_resource->kind()) {
    case BLEResource::REMOTE_DEVICE: {
      auto device = reinterpret_cast<BLERemoteDeviceResource*>(ble_resource);
      mtu = ble_att_mtu(device->handle());
      break;
    }
    case BLEResource::CHARACTERISTIC: {
      auto characteristic = reinterpret_cast<BLECharacteristicResource*>(ble_resource);
      int min_sub_mtu = -1;
      for (const auto &subscription: characteristic->subscriptions()) {
        uint16 sub_mtu = ble_att_mtu(subscription->conn_handle());
        if (min_sub_mtu == -1) min_sub_mtu = sub_mtu;
        else min_sub_mtu = min(min_sub_mtu, sub_mtu);
      }
      if (min_sub_mtu != -1) mtu = min_sub_mtu;
      break;
    }
    default:
      INVALID_ARGUMENT;
  }
  return Smi::from(mtu);
}

PRIMITIVE(set_preferred_mtu) {
  ARGS(int, mtu)
  if (mtu > BLE_ATT_MTU_MAX) INVALID_ARGUMENT;

  int result = ble_att_set_preferred_mtu(mtu);

  if (result) {
    INVALID_ARGUMENT;
  } else {
    return process->program()->null_object();
  }
}

PRIMITIVE(get_error) {
  ARGS(Resource, resource)
  auto err_resource = reinterpret_cast<BLEErrorCapableResource*>(resource);
  if (err_resource->error() == 0) OTHER_ERROR;

  return nimble_error_code_to_string(process, err_resource->error(), true);
}

PRIMITIVE(gc) {
  ARGS(Resource, resource)
  auto err_resource = reinterpret_cast<BLEErrorCapableResource*>(resource);
  if (err_resource->has_malloc_error()) {
    err_resource->set_malloc_error(false);
    CROSS_PROCESS_GC;
  }

  return process->program()->null_object();
}

} // namespace toit

#endif // defined(TOIT_FREERTOS) && defined(CONFIG_BT_ENABLED)
