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
#include <store/config/ble_store_config.h>


namespace toit {

const int kInvalidBle = -1;
const int kInvalidHandle = UINT16_MAX;

// Only allow one instance of BLE running.
ResourcePool<int, kInvalidBle> ble_pool(
    0
);

class DiscoveredPeripheral;
typedef DoubleLinkedList<DiscoveredPeripheral> DiscoveredPeripheralList;

class DiscoveredPeripheral : public DiscoveredPeripheralList::Element {
 public:
  DiscoveredPeripheral(ble_addr_t addr, int8 rssi, uint8* data, uint8 data_length, uint8 event_type)
      : addr_(addr)
      , rssi_(rssi)
      , data_(data)
      , data_length_(data_length)
      , event_type_(event_type) {}

  ~DiscoveredPeripheral() {
    free(data_);
  }

  ble_addr_t addr() { return addr_; }
  int8 rssi() const { return rssi_; }
  uint8* data() { return data_; }
  uint8 data_length() const { return data_length_; }
  uint8 event_type() const { return event_type_; }

 private:
  ble_addr_t addr_;
  int8 rssi_;
  uint8* data_;
  uint8 data_length_;
  uint8 event_type_;
};

// The thread on the BleResourceGroup is responsible for running the nimble background thread. All events from the
// nimble background thread are delivered through call backs to registered callback methods. The callback methods
// will then send the events to the EventSource to enable the normal resource state notification mechanism. This is
// done with the call BleEventSource::instance()->on_event(<resource>, <kBLE* event id>).
class BleResourceGroup : public ResourceGroup, public Thread {
 public:
  TAG(BleResourceGroup);
  BleResourceGroup(Process* process, BleEventSource* event_source, int id, Mutex* mutex)
      : ResourceGroup(process, event_source)
      , Thread("BLE")
      , id_(id)
      , sync_(false)
      , mutex_(mutex) {
    ASSERT(!instance_)
    // Note that the resource group creation is guarded by the resource pool of size 1,
    // so there can never be two instances created and it is safe to set the static variable
    // here.
    instance_ = this;
    spawn(CONFIG_NIMBLE_TASK_STACK_SIZE);
  }

  void tear_down() override {
    FATAL_IF_NOT_ESP_OK(nimble_port_stop());
    join();

    nimble_port_deinit();

    FATAL_IF_NOT_ESP_OK(esp_nimble_hci_and_controller_deinit());

    ble_pool.put(id_);

    ResourceGroup::tear_down();
  }

  static BleResourceGroup* instance() { return instance_; }

  Mutex* mutex() { return mutex_; }

  // The BLE Host will notify when the BLE subsystem is synchronized. Before a successful sync, most
  // operation will not succeed.
  void set_sync(bool sync) {
    sync_ = sync;
    if (sync) {
      for (auto resource : resources()) {
        auto ble_resource = reinterpret_cast<BleResource*>(resource);
        BleEventSource::instance()->on_event(ble_resource, kBleStarted);
      }
    }
  }

  bool sync() const { return sync_; }
  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

 protected:
  void entry() override{
    nimble_port_run();
  }

  ~BleResourceGroup() override {
    instance_ = null;
  }

 private:
  int id_;
  bool sync_;
  Mutex* mutex_;
  static BleResourceGroup* instance_;
};

// There can be only one active BleResourceGroup. This reference will be
// active when the resource group exists
BleResourceGroup* BleResourceGroup::instance_ = null;

class DiscoverableResource {
 public:
  DiscoverableResource() : returned_(false) {}
  bool is_returned() const { return returned_; }
  void set_returned(bool returned) { returned_ = returned; }

 private:
  bool returned_;
};

class BleErrorCapableResource: public BleResource {
 public:
  BleErrorCapableResource(ResourceGroup* group, Kind kind)
      : BleResource(group, kind)
      , malloc_error_(false)
      , error_(0) {}

  bool has_malloc_error() const { return malloc_error_;}
  void set_malloc_error(bool malloc_error) { malloc_error_ = malloc_error; }
  int error() const { return error_; }
  void set_error(int error) { error_ = error; }

 private:
  bool malloc_error_;
  int error_;
};

class BleServiceResource;

class BleReadWriteElement : public BleErrorCapableResource {
 public:
  BleReadWriteElement(ResourceGroup* group, Kind kind, ble_uuid_any_t uuid, uint16 handle)
      : BleErrorCapableResource(group, kind)
      , uuid_(uuid)
      , handle_(handle)
      , mbuf_received_(null)
      , mbuf_to_send_(null)
      , read_request_mbuf_(null)
      , read_request_mutex_(null)
      , read_request_condition_(null)
      , read_timeout_ms_(0) {}

  ~BleReadWriteElement() override {
    if (mbuf_received_) os_mbuf_free_chain(mbuf_received_);
    if (mbuf_to_send_) os_mbuf_free(mbuf_to_send_);
    if (read_request_mbuf_) os_mbuf_free(read_request_mbuf_);
    if (read_request_mutex_) OS::dispose(read_request_mutex_);
    if (read_request_condition_) OS::dispose(read_request_condition_);
  }

  ble_uuid_any_t &uuid() { return uuid_; }
  ble_uuid_t* ptr_uuid() { return &uuid_.u; }
  uint16 handle() const { return handle_; }
  uint16* ptr_handle() { return &handle_; }
  virtual BleServiceResource* service() = 0;

  void set_mbuf_received(os_mbuf* mbuf) {
    if (mbuf_received_ == null)  {
      mbuf_received_ = mbuf;
    } else if (mbuf == null) {
      os_mbuf_free_chain(mbuf_received_);
      mbuf_received_ = null;
    } else {
      os_mbuf_concat(mbuf_received_, mbuf);
    }
  }

  os_mbuf* mbuf_received() {
    return mbuf_received_;
  }

  os_mbuf* mbuf_to_send() {
    Locker locker(BleResourceGroup::instance()->mutex());
    return mbuf_to_send(locker);
  }

  os_mbuf* mbuf_to_send(Locker& locker) {
    return mbuf_to_send_;
  }

  void set_mbuf_to_send(os_mbuf* mbuf) {
    Locker locker(BleResourceGroup::instance()->mutex());
    if (mbuf_to_send_ != null) os_mbuf_free(mbuf_to_send_);
    mbuf_to_send_ = mbuf;
  }

  static int on_attribute_read(uint16_t conn_handle,
                               const ble_gatt_error *error,
                               ble_gatt_attr *attr,
                               void *arg) {
    USE(conn_handle);
    unvoid_cast<BleReadWriteElement*>(arg)->_on_attribute_read(error, attr);
    return BLE_ERR_SUCCESS;
  }

  static int on_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg) {
    USE(conn_handle);
    USE(attr_handle);
    return unvoid_cast<BleReadWriteElement*>(arg)->_on_access(ctxt);
  }

  static uint16_t mbuf_total_len(os_mbuf* om) {
    if (!om) return 0;
    uint16_t total_len = 0;
    while (om) {
      total_len += om->om_len;
      om = SLIST_NEXT(om, om_next);
    }
    return total_len;
  }

  bool setup_callback_readable_characteristic(int read_timeout_ms) {
    read_request_mutex_ = OS::allocate_mutex(1, "Read request");
    if (!read_request_mutex_) return false;
    read_request_condition_ = OS::allocate_condition_variable(read_request_mutex_);
    if (!read_request_condition_) {
      OS::dispose(read_request_mutex_);
      return false;
    }
    read_timeout_ms_ = read_timeout_ms;
    return true;
  }

  void handle_read_reply_request(os_mbuf* mbuf) {
    Locker locker(read_request_mutex_);
    if (read_request_mbuf_ != null) os_mbuf_free(read_request_mbuf_);
    read_request_mbuf_ = mbuf;
    OS::signal_all(read_request_condition_);
  }

 private:
  void _on_attribute_read(const ble_gatt_error *error, ble_gatt_attr *attr);
  int _on_access(ble_gatt_access_ctxt* ctxt);

  ble_uuid_any_t uuid_;
  uint16 handle_;
  os_mbuf* mbuf_received_;
  os_mbuf* mbuf_to_send_;
  os_mbuf* read_request_mbuf_;
  Mutex* read_request_mutex_;
  ConditionVariable* read_request_condition_;
  int read_timeout_ms_;
};

class BleDescriptorResource;
typedef DoubleLinkedList<BleDescriptorResource> DescriptorList;
class BleCharacteristicResource;

class BleDescriptorResource: public BleReadWriteElement, public DescriptorList::Element, public DiscoverableResource {
 public:
  TAG(BleDescriptorResource);
  BleDescriptorResource(ResourceGroup* group, BleCharacteristicResource *characteristic,
                        ble_uuid_any_t uuid, uint16 handle, int properties)
    : BleReadWriteElement(group, DESCRIPTOR, uuid, handle)
    , characteristic_(characteristic)
    , properties_(properties) {}

  BleServiceResource* service() override;
  uint8 properties() const { return properties_; }

 private:
  BleCharacteristicResource* characteristic_;
  uint8 properties_;
};

class Subscription;
typedef class DoubleLinkedList<Subscription> SubscriptionList;
class Subscription : public SubscriptionList::Element {
 public:
  Subscription(bool indication, bool notification, uint16 conn_handle)
      : indication_(indication)
      , notification_(notification)
      , conn_handle_(conn_handle) {}

  void set_indication(bool indication) { indication_ = indication; }
  bool indication() const { return indication_; }
  void set_notification(bool notification) { notification_ = notification; }
  bool notification() const { return notification_; }
  uint16 conn_handle() const { return conn_handle_; }

 private:
  bool indication_;
  bool notification_;
  uint16 conn_handle_;
};

typedef DoubleLinkedList<BleCharacteristicResource> CharacteristicResourceList;

class BleCharacteristicResource :
    public BleReadWriteElement, public CharacteristicResourceList::Element, public DiscoverableResource {
 public:
  TAG(BleCharacteristicResource);
  BleCharacteristicResource(BleResourceGroup* group, BleServiceResource* service,
                            ble_uuid_any_t uuid, uint16 properties, uint16 handle,
                            uint16 definition_handle)
      : BleReadWriteElement(group, CHARACTERISTIC, uuid, handle)
      , service_(service)
      , properties_(properties)
      , definition_handle_(definition_handle) {}

  ~BleCharacteristicResource() override {
    while (!subscriptions_.is_empty()) {
      auto subscription = subscriptions_.remove_first();
      delete subscription;
    }
  }

  BleServiceResource* service() override { return service_; }

  uint16 properties() const { return properties_;  }
  uint16 definition_handle() const { return definition_handle_; }

  BleDescriptorResource* get_or_create_descriptor(ble_uuid_any_t uuid, uint16_t handle,
                                                  uint8 properties, bool can_create = false);

  BleDescriptorResource* find_descriptor(ble_uuid_any_t& uuid) {
    return get_or_create_descriptor(uuid, 0, 0, false);
  }

  // Finds the Client Characteristic Configuration Descriptor.
  const BleDescriptorResource* find_cccd() {
    ble_uuid_any_t uuid;
    uuid.u16.u.type = BLE_UUID_TYPE_16;
    uuid.u16.value = BLE_GATT_DSC_CLT_CFG_UUID16; // UUID for Client Characteristic Configuration Descriptor.
    return find_descriptor(uuid);
  }

  DescriptorList& descriptors() {
    return descriptors_;
  }

  bool update_subscription_status(uint8_t indicate, uint8_t notify, uint16_t conn_handle);
  SubscriptionList& subscriptions() { return subscriptions_; }

  static int on_write_response(uint16_t conn_handle,
                               const ble_gatt_error* error,
                               ble_gatt_attr* attr,
                               void* arg) {
    USE(conn_handle);
    unvoid_cast<BleCharacteristicResource*>(arg)->_on_write_response(error, attr);
    return BLE_ERR_SUCCESS;
  }

  static int on_subscribe_response(uint16_t conn_handle,
                                  const ble_gatt_error* error,
                                  ble_gatt_attr* attr,
                                  void* arg) {
    USE(conn_handle);
    unvoid_cast<BleCharacteristicResource*>(arg)->_on_subscribe_response(error, attr);
    return BLE_ERR_SUCCESS;
  }

 private:
  void _on_write_response(const ble_gatt_error* error, ble_gatt_attr* attr);
  void _on_subscribe_response(const ble_gatt_error* error, ble_gatt_attr* attr);

  BleServiceResource* service_;
  uint16 properties_;
  uint16 definition_handle_;
  DescriptorList descriptors_;
  SubscriptionList subscriptions_;
};

typedef DoubleLinkedList<BleServiceResource> ServiceResourceList;
class BleRemoteDeviceResource;
class BlePeripheralManagerResource;

class BleServiceResource:
    public BleErrorCapableResource, public ServiceResourceList::Element, public DiscoverableResource {
 private:
  BleServiceResource(BleResourceGroup* group,
                     ble_uuid_any_t uuid, uint16 start_handle, uint16 end_handle)
      : BleErrorCapableResource(group, SERVICE)
      , uuid_(uuid)
      , start_handle_(start_handle)
      , end_handle_(end_handle)
      , characteristics_discovered_(false)
      , device_(null)
      , peripheral_manager_(null) {}

 public:
  TAG(BleServiceResource);
  BleServiceResource(BleResourceGroup* group, BleRemoteDeviceResource* device,
                     ble_uuid_any_t uuid, uint16 start_handle, uint16 end_handle)
      : BleServiceResource(group, uuid, start_handle, end_handle) {
    device_ = device;
  }

  BleServiceResource(BleResourceGroup* group, BlePeripheralManagerResource* peripheral_manager,
                     ble_uuid_any_t uuid, uint16 start_handle, uint16 end_handle)
      : BleServiceResource(group, uuid, start_handle, end_handle) {
    peripheral_manager_ = peripheral_manager;
  }

  ~BleServiceResource() override {
    if (!deployed()) return;
    dispose_gatt_svr_chars(gatt_svr_chars_, gatt_svr_chars_count_);
  }

  BleCharacteristicResource* get_or_create_characteristics_resource(
      ble_uuid_any_t uuid, uint16 properties, uint16 def_handle,
      uint16 value_handle);

  ble_uuid_any_t& uuid() { return uuid_; }
  ble_uuid_t* ptr_uuid() { return &uuid_.u; }
  uint16 start_handle() const { return start_handle_; }
  uint16 end_handle() const { return end_handle_; }

  BleRemoteDeviceResource* device() const { return device_; }
  BlePeripheralManagerResource* peripheral_manager() const { return peripheral_manager_; }
  CharacteristicResourceList& characteristics() { return characteristics_; }

  void clear_characteristics() {
    while (auto characteristic = characteristics_.remove_first()) {
      group()->unregister_resource(characteristic);
    }
  }

  bool deployed() const { return gatt_svr_chars_count_ >= 0; }

  void set_svr_chars(ble_gatt_chr_def* chars, int count) {
    ASSERT(count >= 0);
    gatt_svr_chars_ = chars;
    gatt_svr_chars_count_ = count;
  }


  bool characteristics_discovered() const { return characteristics_discovered_; }
  void set_characteristics_discovered(bool discovered) { characteristics_discovered_ = discovered; }

  static int on_characteristic_discovered(uint16_t conn_handle,
                                          const ble_gatt_error* error,
                                          const ble_gatt_chr* chr, void* arg) {
    USE(conn_handle);
    unvoid_cast<BleServiceResource*>(arg)->_on_characteristic_discovered(error, chr);
    return BLE_ERR_SUCCESS;
  }

  static int on_descriptor_discovered(uint16_t conn_handle,
                                      const struct ble_gatt_error *error,
                                      uint16_t chr_val_handle,
                                      const struct ble_gatt_dsc *dsc,
                                      void *arg) {
    USE(conn_handle);
    unvoid_cast<BleServiceResource*>(arg)->_on_descriptor_discovered(error, dsc, chr_val_handle, false);
    return BLE_ERR_SUCCESS;
  }

  static void dispose_gatt_svr_chars(ble_gatt_chr_def* gatt_svr_chars, int count) {
    for (int i = 0; i < count; i++) {
      free(gatt_svr_chars[i].descriptors);
    }
    free(gatt_svr_chars);
  }

 private:
  void _on_characteristic_discovered(const ble_gatt_error *error, const ble_gatt_chr *chr);
  void _on_descriptor_discovered(const struct ble_gatt_error* error,
                                 const struct ble_gatt_dsc* dsc,
                                 uint16_t chr_val_handle,
                                 bool called_from_notify);

  CharacteristicResourceList characteristics_;
  ble_uuid_any_t uuid_;
  uint16 start_handle_;
  uint16 end_handle_;
  bool characteristics_discovered_;
  BleRemoteDeviceResource* device_;
  BlePeripheralManagerResource* peripheral_manager_;

  ble_gatt_chr_def* gatt_svr_chars_ = null;
  int gatt_svr_chars_count_ = -1;
};

class BleCentralManagerResource : public BleErrorCapableResource {
 public:
  TAG(BleCentralManagerResource);

  explicit BleCentralManagerResource(BleResourceGroup* group)
      : BleErrorCapableResource(group, CENTRAL_MANAGER) {}

  ~BleCentralManagerResource() override {
    if (is_scanning()) {
      int err = ble_gap_disc_cancel();
      if (err != BLE_ERR_SUCCESS && err != BLE_HS_EALREADY) {
        fail("Failed to cancel discovery");
      }
    }

    while (auto peripheral = remove_discovered_peripheral()) {
      delete peripheral;
    }
  }

  static bool is_scanning() { return ble_gap_disc_active(); }

  DiscoveredPeripheral* get_discovered_peripheral() {
    return newly_discovered_peripherals_.first();
  }

  DiscoveredPeripheral* remove_discovered_peripheral() {
    return newly_discovered_peripherals_.remove_first();
  }

  static int on_discovery(ble_gap_event *event, void *arg) {
    unvoid_cast<BleCentralManagerResource*>(arg)->_on_discovery(event);
    return BLE_ERR_SUCCESS;
  }

 private:
  void _on_discovery(ble_gap_event *event);
  DiscoveredPeripheralList newly_discovered_peripherals_;
};

template <typename T>
class ServiceContainer : public BleErrorCapableResource {
 public:
  ServiceContainer(BleResourceGroup* group, Kind kind)
      : BleErrorCapableResource(group, kind) {}

  virtual T* type() = 0;
  BleServiceResource* get_or_create_service_resource(ble_uuid_any_t uuid, uint16 start, uint16 end);
  ServiceResourceList& services() { return services_; }

  void clear_services() {
    while (auto service = services_.remove_first()) {
      group()->unregister_resource(service);
    }
  }

 private:
  ServiceResourceList services_;
};

class BlePeripheralManagerResource : public ServiceContainer<BlePeripheralManagerResource> {
 public:
  TAG(BlePeripheralManagerResource);
  explicit BlePeripheralManagerResource(BleResourceGroup* group)
      : ServiceContainer(group, PERIPHERAL_MANAGER)
      , advertising_params_({})
      , advertising_started_(false) {}

  ~BlePeripheralManagerResource() override {
    if (is_advertising()) {
      FATAL_IF_NOT_ESP_OK(ble_gap_adv_stop());
    }
  }

  BlePeripheralManagerResource* type() override { return this; }

  bool advertising_started() const { return advertising_started_; }
  void set_advertising_started(bool advertising_started)  { advertising_started_ = advertising_started; }

  ble_gap_adv_params& advertising_params() { return advertising_params_; }

  static int on_gap(struct ble_gap_event* event, void* arg) {
    return unvoid_cast<BlePeripheralManagerResource*>(arg)->_on_gap(event);
  }
  static bool is_advertising() { return ble_gap_adv_active(); }

 private:
  int _on_gap(struct ble_gap_event* event);
  ble_gap_adv_params advertising_params_;
  bool advertising_started_;
};

class BleRemoteDeviceResource : public ServiceContainer<BleRemoteDeviceResource> {
 public:
  TAG(BleRemoteDeviceResource);
  explicit BleRemoteDeviceResource(BleResourceGroup* group, bool secure_connection)
    : ServiceContainer(group, REMOTE_DEVICE)
    , handle_(kInvalidHandle)
    , secure_connection_(secure_connection) {}

  BleRemoteDeviceResource* type() override { return this; }

  static int on_event(ble_gap_event *event, void *arg) {
    unvoid_cast<BleRemoteDeviceResource*>(arg)->_on_event(event);
    return BLE_ERR_SUCCESS;
  }

  static int on_service_discovered(uint16_t conn_handle,
                                   const struct ble_gatt_error *error,
                                   const struct ble_gatt_svc *service,
                                   void *arg) {
    unvoid_cast<BleRemoteDeviceResource*>(arg)->_on_service_discovered(error, service);
    return BLE_ERR_SUCCESS;
  }

  uint16 handle() const { return handle_; }
  void set_handle(uint16 handle) { handle_ = handle; }

 private:
  void _on_event(ble_gap_event *event);
  void _on_service_discovered(const ble_gatt_error* error, const ble_gatt_svc* service);

  uint16 handle_;
  bool secure_connection_;
};

Object* nimble_error_code_to_string(Process* process, int error_code, bool host) {
  static const size_t BUFFER_LEN = 400;
  char buffer[BUFFER_LEN];
  const char* gist = "https://gist.github.com/mikkeldamsgaard/0857ce6a8b073a52d6f07973a441ad54";
  int length = snprintf(buffer, BUFFER_LEN, "NimBLE error, Type: %s, error code: 0x%02x. See %s",
                        host ? "host" : "client",
                        error_code % 0x100,
                        gist);
  String* str = process->allocate_string(buffer, length);
  if (!str) FAIL(ALLOCATION_FAILED);
  return Primitive::mark_as_error(str);
}

static Object* nimble_stack_error(Process* process, int error_code) {
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
    default: {
      uuid.u.type = BLE_UUID_TYPE_128;
      memcpy_reverse(uuid.u128.value, blob.address(), 16);
      break;
    }
  }
  return uuid;
}

static ByteArray* byte_array_from_uuid(Process* process, ble_uuid_any_t uuid, Error** err) {
  *err = null;

  ByteArray* byte_array = process->object_heap()->allocate_internal_byte_array(uuid.u.type / 8);
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
      *reinterpret_cast<uint32*>(bytes.address()) = __builtin_bswap32(uuid.u32.value);
      break;
    default:
      memcpy_reverse(bytes.address(), uuid.u128.value, sizeof(uuid.u128.value));
      break;
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
      return memcmp(uuid.u128.value, other.u128.value, sizeof(uuid.u128.value)) == 0;
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

uint32_t BleResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  USE(resource);
  state |= data;
  return state;
}

BleServiceResource* BleDescriptorResource::service() {
  return characteristic_->service();
}

template<typename T>
BleServiceResource*
ServiceContainer<T>::get_or_create_service_resource(ble_uuid_any_t uuid, uint16 start, uint16 end) {
  for (auto service : services_) {
    if (uuid_equals(uuid, service->uuid())) return service;
  }
  auto service = _new BleServiceResource(group(),type(), uuid, start,end);
  if (!service) return null;
  group()->register_resource(service);
  services_.append(service);
  return service;
}

void
BleServiceResource::_on_characteristic_discovered(const struct ble_gatt_error* error, const struct ble_gatt_chr* chr) {
  switch (error->status) {
    case 0: {
      auto ble_characteristic =
          get_or_create_characteristics_resource(
              chr->uuid, chr->properties, chr->def_handle,
              chr->val_handle);
      if (!ble_characteristic) {
        set_malloc_error(true);
      }
      break;
    }
    case BLE_HS_EDONE: // No more characteristics can be discovered.
      if (has_malloc_error()) {
        clear_characteristics();
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        ble_gattc_disc_all_dscs(device()->handle(),
                                start_handle(),
                                end_handle(),
                                BleServiceResource::on_descriptor_discovered,
                                this);
      }
      break;
    default:
      clear_characteristics();
      if (has_malloc_error()) {
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        set_error(error->status);
        BleEventSource::instance()->on_event(this, kBleDiscoverOperationFailed);
      }
      break;

  }
}

BleCharacteristicResource* BleServiceResource::get_or_create_characteristics_resource(
    ble_uuid_any_t uuid, uint16 properties, uint16 def_handle,
    uint16 value_handle) {
  auto characteristic = _new BleCharacteristicResource(group(), this, uuid, properties, value_handle, def_handle);
  if (!characteristic) return null;
  group()->register_resource(characteristic);
  characteristics_.append(characteristic);
  return characteristic;
}

void BleCentralManagerResource::_on_discovery(ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_DISC_COMPLETE:
      BleEventSource::instance()->on_event(this, kBleCompleted);
      break;
    case BLE_GAP_EVENT_DISC: {
      uint8* data = null;
      uint8 data_length = 0;
      if (event->disc.length_data > 0) {
        data = unvoid_cast<uint8*>(malloc(event->disc.length_data));
        if (!data) {
          set_malloc_error(true);
          BleEventSource::instance()->on_event(this, kBleMallocFailed);
          return;
        }
        memmove(data, event->disc.data, event->disc.length_data);
        data_length = event->disc.length_data;
      }

      auto discovered_peripheral = _new DiscoveredPeripheral(
          event->disc.addr, event->disc.rssi, data, data_length, event->disc.event_type);

      if (!discovered_peripheral) {
        if (data) free(data);
        set_malloc_error(true);
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
        return;
      }

      {
        Locker locker(BleResourceGroup::instance()->mutex());
        newly_discovered_peripherals_.append(discovered_peripheral);
      }

      BleEventSource::instance()->on_event(this, kBleDiscovery);
    }
  }
}

void BleRemoteDeviceResource::_on_event(ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (event->connect.status == 0) {
        ASSERT(handle() == kInvalidHandle)
        set_handle(event->connect.conn_handle);
        // TODO(mikkel): Expose this as a primitive.
        ble_gattc_exchange_mtu(event->connect.conn_handle, null, null);
      } else {
        BleEventSource::instance()->on_event(this, kBleConnectFailed);
      }
      break;
    case BLE_GAP_EVENT_DISCONNECT:
      BleEventSource::instance()->on_event(this, kBleDisconnected);
      break;
    case BLE_GAP_EVENT_NOTIFY_RX:
      // Notify/indicate update.

      // TODO(mikkel): More efficient data structure.
      for (auto service: services()) {
        for (auto characteristic: service->characteristics()) {
          if (characteristic->handle() == event->notify_rx.attr_handle) {
            {
              Locker locker(BleResourceGroup::instance()->mutex());
              characteristic->set_mbuf_received(event->notify_rx.om);
            }
            event->notify_rx.om = null;
            BleEventSource::instance()->on_event(characteristic, kBleValueDataReady);
            return;
          }
        }
      }
      break;
    case BLE_GAP_EVENT_MTU:
      if (secure_connection_) {
        ble_gap_security_initiate(event->mtu.conn_handle);
      } else {
        BleEventSource::instance()->on_event(this, kBleConnected);
      }
      break;
    case BLE_GAP_EVENT_ENC_CHANGE:
      if (secure_connection_) {
        BleEventSource::instance()->on_event(this, kBleConnected);
      }
      break;
  }
}

void BleRemoteDeviceResource::_on_service_discovered(const ble_gatt_error* error, const ble_gatt_svc* service) {
  switch (error->status) {
    case 0: {
      auto ble_service = get_or_create_service_resource(service->uuid, service->start_handle, service->end_handle);
      if (!ble_service) {
        set_malloc_error(true);
      }
      break;
    }
    case BLE_HS_EDONE: // No more services can be discovered.
      if (has_malloc_error()) {
        clear_services();
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        BleEventSource::instance()->on_event(this, kBleServicesDiscovered);
      }
      break;
    default:
      clear_services();
      if (has_malloc_error()) {
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        set_error(error->status);
        BleEventSource::instance()->on_event(this, kBleDiscoverOperationFailed);
      }
      break;
  }
}

BleDescriptorResource* BleCharacteristicResource::get_or_create_descriptor(
    ble_uuid_any_t uuid, uint16_t handle, uint8 properties, bool can_create) {
  for (auto descriptor : descriptors_) {
    if (uuid_equals(uuid, descriptor->uuid())) return descriptor;
  }
  if (!can_create) return null;

  auto descriptor = _new BleDescriptorResource(group(), this, uuid, handle, properties);
  if (!descriptor) return null;
  group()->register_resource(descriptor);
  descriptors_.append(descriptor);
  return descriptor;
}

void BleReadWriteElement::_on_attribute_read(
    const struct ble_gatt_error* error,
    struct ble_gatt_attr* attr) {
  switch (error->status) {
    case 0: {
      {
        Locker locker(BleResourceGroup::instance()->mutex());
        set_mbuf_received(attr->om);
      }
      // Take ownership of the buffer.
      attr->om = null;
      BleEventSource::instance()->on_event(this, kBleValueDataReady);
      break;
    }
    case BLE_HS_EDONE: // No more data can be read.
      break;

    default:
      set_error(error->status);
      BleEventSource::instance()->on_event(this, kBleValueDataReadFailed);
      break;
  }
}

int BleReadWriteElement::_on_access(ble_gatt_access_ctxt* ctxt) {
  switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
    case BLE_GATT_ACCESS_OP_READ_DSC:
      if (mbuf_to_send() != null) {
        Locker locker(BleResourceGroup::instance()->mutex());
        return os_mbuf_appendfrom(ctxt->om, mbuf_to_send(locker), 0, mbuf_total_len(mbuf_to_send_));
      } else {
        BleEventSource::instance()->on_event(this, kBleDataReadRequest);
        {
          Locker locker(read_request_mutex_);
          if (!OS::wait_us(read_request_condition_, 1000 * read_timeout_ms_)) return BLE_ERR_OPERATION_CANCELLED;
          if (read_request_mbuf_) {
            int result = os_mbuf_appendfrom(ctxt->om, read_request_mbuf_, 0, mbuf_total_len(read_request_mbuf_));
            os_mbuf_free(read_request_mbuf_);
            read_request_mbuf_ = null;
            return result;
          } else {  // Empty response
            return BLE_ERR_SUCCESS;
          }
        }
      }
      break;
    case BLE_GATT_ACCESS_OP_WRITE_CHR:
    case BLE_GATT_ACCESS_OP_WRITE_DSC:
      {
        Locker locker(BleResourceGroup::instance()->mutex());
        set_mbuf_received(ctxt->om);
      }
      ctxt->om = null;
      BleEventSource::instance()->on_event(this, kBleDataReceived);
      break;
    default:
      // Unhandled event, no dispatching.
      return 0;
  }
  return BLE_ERR_SUCCESS;
}

void BleCharacteristicResource::_on_write_response(
    const struct ble_gatt_error* error,
    struct ble_gatt_attr* attr) {
  USE(attr);
  switch (error->status & 0xFF) {
    case 0:
    case BLE_HS_EDONE:
      BleEventSource::instance()->on_event(this, kBleValueWriteSucceeded);
      break;
    default:
      set_error(error->status);
      BleEventSource::instance()->on_event(this, kBleValueWriteFailed);
      break;
  }
}

void BleCharacteristicResource::_on_subscribe_response(
    const struct ble_gatt_error* error,
    struct ble_gatt_attr* attr) {
  USE(attr);
  switch (error->status) {
    case 0:
    case BLE_HS_EDONE:
      BleEventSource::instance()->on_event(this, kBleSubscriptionOperationSucceeded);
      break;
    default:
      set_error(error->status);
      BleEventSource::instance()->on_event(this, kBleSubscriptionOperationFailed);
      break;
  }
}

void
BleServiceResource::_on_descriptor_discovered(const struct ble_gatt_error* error, const struct ble_gatt_dsc* dsc,
                                              uint16_t chr_val_handle, bool called_from_notify) {
  switch (error->status) {
    case 0: {
      // Find the characteristic.
      BleCharacteristicResource* characteristic = null;

      for (auto current : characteristics_) {
        if (!characteristic) {
          if (dsc->handle <= start_handle()) return;
        } else {
          if (characteristic->definition_handle() <= dsc->handle && dsc->handle <= characteristic->handle()) return;
          if (characteristic->handle() < dsc->handle && dsc->handle < current->definition_handle()) break;
        }
        characteristic = current;
      }
      if (dsc->handle <= characteristic->handle()) return;
      auto descriptor = characteristic->get_or_create_descriptor(dsc->uuid, dsc->handle, 0, true);
      if (!descriptor) {
        set_malloc_error(true);
      }
      break;
    }

    case BLE_HS_EDONE:
      if (has_malloc_error()) {
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        set_characteristics_discovered(true);
        BleEventSource::instance()->on_event(this, kBleCharacteristicsDiscovered);
      }
      break;

    default:
      if (has_malloc_error()) {
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        set_error(error->status);
        if (called_from_notify) {
          BleEventSource::instance()->on_event(this, kBleSubscriptionOperationFailed);
        } else {
          BleEventSource::instance()->on_event(this, kBleDescriptorsDiscovered);
        }
        break;
      }
  }
}

bool BleCharacteristicResource::update_subscription_status(uint8_t indicate, uint8_t notify, uint16_t conn_handle) {
  for (auto subscription : subscriptions_) {
    if (subscription->conn_handle() == conn_handle) {
      if (!indicate && !notify) {
        subscriptions_.unlink(subscription);
        delete subscription;
        return true;
      } else {
        subscription->set_indication(indicate);
        subscription->set_notification(notify);
        return true;
      }
    }
  }

  auto subscription = _new Subscription(indicate, notify, conn_handle);
  if (!subscription) {
    // Since this method is called from the BLE event handler and there is no
    // toit code monitoring the interaction, we resort to calling gc by hand to
    // try to recover on OOM.
    VM::current()->scheduler()->gc(null, /* malloc_failed = */ true, /* try_hard = */ true);
    subscription = _new Subscription(indicate, notify, conn_handle);
    if (!subscription) return false;
  }

  subscriptions_.append(subscription);
  return true;
}

int BlePeripheralManagerResource::_on_gap(struct ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (advertising_started()) {
        // NimBLE stops advertising on connection event. To keep the library consistent
        // with other platforms the advertising is restarted.
        int err = ble_gap_adv_start(
            BLE_OWN_ADDR_PUBLIC,
            null,
            BLE_HS_FOREVER,
            &advertising_params(),
            BlePeripheralManagerResource::on_gap,
            this);
        if (err != BLE_ERR_SUCCESS) {
          ESP_LOGW("BLE", "Could not restart advertising: err=%d", err);
        }
      }
      break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
      // TODO(mikkel): Add stopped event.
      // BleEventSource::instance()->on_event(this, kBleAdvertiseStopped);
      break;
    case BLE_GAP_EVENT_SUBSCRIBE: {
      for (auto service : services()) {
        for (auto characteristic : service->characteristics()) {
          if (characteristic->handle() == event->subscribe.attr_handle) {
            bool success = characteristic->update_subscription_status(
                event->subscribe.cur_indicate,
                event->subscribe.cur_notify,
                event->subscribe.conn_handle);
            return success ? BLE_ERR_SUCCESS : BLE_ERR_MEM_CAPACITY;
          }
        }
      }
      break;
    }
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
      ble_gap_conn_desc connection_description = {};
      ble_gap_conn_find(event->repeat_pairing.conn_handle, &connection_description);
      ble_store_util_delete_peer(&connection_description.peer_id_addr);
      return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
  }

  return BLE_ERR_SUCCESS;
}

static Object* object_to_mbuf(Process* process, Object* object, os_mbuf** result) {
  *result = null;
  if (object != process->null_object()) {
    Blob bytes;
    if (!object->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
    if (bytes.length() > 0) {
      os_mbuf* mbuf = ble_hs_mbuf_from_flat(bytes.address(), bytes.length());
      // A null response is not an allocation error, as the mbufs are allocated on boot based on configuration settings.
      // Therefore, a GC will do little to help the situation and will eventually result in the VM thinking it is out of memory.
      // The mbuf will be freed eventually by the NimBLE stack. The client code will
      // have to wait and then try again.
      if (!mbuf) FAIL(QUOTA_EXCEEDED);
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
    BleResourceGroup* instance = BleResourceGroup::instance();
    if (instance) {
      Locker locker(instance->mutex());

      instance->set_sync(true);
      ble_gatts_reset();
    }
  }
}

MODULE_IMPLEMENTATION(ble, MODULE_BLE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int id = ble_pool.any();
  if (id == kInvalidBle) FAIL(ALREADY_IN_USE);

  esp_err_t err = esp_nimble_hci_and_controller_init();

  // TODO(anders): Enable these to improve BLE/WiFi coop?
  // SystemEventSource::instance()->run([&]() -> void {
  //   esp_coex_preference_set(ESP_COEX_PREFER_BT);
  //   esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
  // });

  if (err != BLE_ERR_SUCCESS) {
    ble_pool.put(id);
    if (err == ESP_ERR_NO_MEM) {
      esp_bt_controller_disable();
      esp_bt_controller_deinit();
      FAIL(MALLOC_FAILED);
    }
    return Primitive::os_error(err, process);
  }

  // Mark usage. When the group is unregistered, the usage is automatically
  // decremented, but if group allocation fails, we manually call unuse().
  BleEventSource* ble = BleEventSource::instance();
  if (!ble->use()) {
    ble_pool.put(id);
    FAIL(MALLOC_FAILED);
  }

  Mutex* mutex = OS::allocate_mutex(0, "BLE");
  if (!mutex) {
    ble->unuse();
    ble_pool.put(id);
    FAIL(MALLOC_FAILED);
  }

  ble_hs_cfg.sync_cb = ble_on_sync;

  // It is important to call nimble_port_init before creating the resource group, as the
  // resource group constructor starts the nimble background thread that uses
  // structures initialize by the init function.
  nimble_port_init();

  auto group = _new BleResourceGroup(process, ble, id, mutex);
  if (!group) {
    OS::dispose(mutex);
    ble->unuse();
    ble_pool.put(id);
    nimble_port_deinit();
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create_central_manager) {
  ARGS(BleResourceGroup, group)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto central_manager = _new BleCentralManagerResource(group);
  if (!central_manager) FAIL(MALLOC_FAILED);

  group->register_resource(central_manager);
  proxy->set_external_address(central_manager);

  {
    Locker locker(BleResourceGroup::instance()->mutex());
    if (group->sync()) BleEventSource::instance()->on_event(central_manager, kBleStarted);
  }

  return proxy;
}

PRIMITIVE(create_peripheral_manager) {
  ARGS(BleResourceGroup, group, bool, bonding, bool, secure_connections)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto peripheral_manager = _new BlePeripheralManagerResource(group);
  if (!peripheral_manager) FAIL(MALLOC_FAILED);

  ble_hs_cfg.sm_bonding = bonding;
  ble_hs_cfg.sm_sc = secure_connections;
  ble_hs_cfg.sm_mitm = secure_connections;
  if (bonding) {
    ble_hs_cfg.sm_our_key_dist = bonding;
    ble_hs_cfg.sm_their_key_dist = bonding;
  }
  ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;

  if (bonding | secure_connections) {
    ble_hs_cfg.store_read_cb = ble_store_config_read;
    ble_hs_cfg.store_write_cb = ble_store_config_write;
    ble_hs_cfg.store_delete_cb = ble_store_config_delete;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
  }

  ble_svc_gap_init();
  ble_svc_gatt_init();

  group->register_resource(peripheral_manager);
  proxy->set_external_address(peripheral_manager);

  {
    Locker locker(BleResourceGroup::instance()->mutex());
    if (group->sync()) {
      ble_gatts_reset();
      BleEventSource::instance()->on_event(peripheral_manager, kBleStarted);
    }
  }

  return proxy;
}

PRIMITIVE(close) {
  ARGS(BleResourceGroup, group)
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(scan_start) {
  ARGS(BleCentralManagerResource, central_manager, int64, duration_us)

  if (BleCentralManagerResource::is_scanning()) FAIL(ALREADY_EXISTS);

  int32 duration_ms = duration_us < 0 ? BLE_HS_FOREVER : static_cast<int>(duration_us / 1000);

  uint8_t own_addr_type;

  /* Figure out address to use while advertising (no privacy for now) */
  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }

  ble_gap_disc_params disc_params{};
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
                     BleCentralManagerResource::on_discovery, central_manager);

  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }

  return process->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BleCentralManagerResource, central_manager)
  Locker locker(BleResourceGroup::instance()->mutex());

  DiscoveredPeripheral* next = central_manager->get_discovered_peripheral();
  if (!next) return process->null_object();

  Array* array = process->object_heap()->allocate_array(7, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  ByteArray* id = process->object_heap()->allocate_internal_byte_array(7);
  if (!id) FAIL(ALLOCATION_FAILED);

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
        if (!name) FAIL(ALLOCATION_FAILED);
        array->at_put(2, name);
      }

      int uuids = fields.num_uuids16 + fields.num_uuids32 + fields.num_uuids128;
      Array* service_classes = process->object_heap()->allocate_array(uuids, Smi::from(0));
      if (!service_classes) FAIL(ALLOCATION_FAILED);

      int index = 0;
      for (int i = 0; i < fields.num_uuids16; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(2);
        if (!service_class) FAIL(ALLOCATION_FAILED);
        ByteArray::Bytes service_class_bytes(service_class);
        *reinterpret_cast<uint16*>(service_class_bytes.address()) = __builtin_bswap16(fields.uuids16[i].value);
        service_classes->at_put(index++, service_class);
      }

      for (int i = 0; i < fields.num_uuids32; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(4);
        if (!service_class) FAIL(ALLOCATION_FAILED);
        ByteArray::Bytes service_class_bytes(service_class);
        *reinterpret_cast<uint32*>(service_class_bytes.address()) = __builtin_bswap32(fields.uuids32[i].value);
        service_classes->at_put(index++, service_class);
      }

      for (int i = 0; i < fields.num_uuids128; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(16);
        if (!service_class) FAIL(ALLOCATION_FAILED);
        ByteArray::Bytes service_class_bytes(service_class);
        memcpy_reverse(service_class_bytes.address(), fields.uuids128[i].value, 16);
        service_classes->at_put(index++, service_class);
      }
      array->at_put(3, service_classes);

      if (fields.mfg_data_len > 0 && fields.mfg_data) {
        ByteArray* custom_data = process->object_heap()->allocate_internal_byte_array(fields.mfg_data_len);
        if (!custom_data) FAIL(ALLOCATION_FAILED);
        ByteArray::Bytes custom_data_bytes(custom_data);
        memcpy(custom_data_bytes.address(), fields.mfg_data, fields.mfg_data_len);
        array->at_put(4, custom_data);
      }

      array->at_put(5, Smi::from(fields.flags));
    }

    array->at_put(6, BOOL(next->event_type() == BLE_HCI_ADV_RPT_EVTYPE_ADV_IND ||
                          next->event_type() == BLE_HCI_ADV_RPT_EVTYPE_DIR_IND));
  }

  central_manager->remove_discovered_peripheral();
  delete next;

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(Resource, resource)

  if (BleCentralManagerResource::is_scanning()) {
    int err = ble_gap_disc_cancel();
    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
    // If ble_gap_disc_cancel returns without an error, the discovery has stopped and NimBLE will not provide an
    // event. So we fire the event manually.
    BleEventSource::instance()->on_event(reinterpret_cast<BleResource*>(resource), kBleCompleted);
  }

  return process->null_object();
}

PRIMITIVE(connect) {
  ARGS(BleCentralManagerResource, central_manager, Blob, address, bool, secure_connection)

  uint8_t own_addr_type;

  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }

  ble_addr_t addr{};
  addr.type = address.address()[0];
  memcpy_reverse(addr.val, address.address() + 1, 6);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);

  auto device = _new BleRemoteDeviceResource(central_manager->group(), secure_connection);
  if (!device) FAIL(MALLOC_FAILED);

  err = ble_gap_connect(own_addr_type, &addr, 3000, null,
                        BleRemoteDeviceResource::on_event, device);
  if (err != BLE_ERR_SUCCESS) {
    delete device;
    return nimble_stack_error(process, err);
  }

  proxy->set_external_address(device);
  central_manager->group()->register_resource(device);
  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(BleRemoteDeviceResource, device)
  ble_gap_terminate(device->handle(), BLE_ERR_REM_USER_CONN_TERM);
  return process->null_object();
}

PRIMITIVE(release_resource) {
  ARGS(Resource, resource)
  resource->resource_group()->unregister_resource(resource);

  return process->null_object();
}

PRIMITIVE(discover_services) {
  ARGS(BleRemoteDeviceResource, device, Array, raw_service_uuids)

  if (raw_service_uuids->length() == 0) {
    int err = ble_gattc_disc_all_svcs(
        device->handle(),
        BleRemoteDeviceResource::on_service_discovered,
        device);
    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
  } else if (raw_service_uuids->length() == 1) {
    Blob blob;
    Object* obj = raw_service_uuids->at(0);
    if (!obj->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
    ble_uuid_any_t uuid = uuid_from_blob(blob);
    int err = ble_gattc_disc_svc_by_uuid(
        device->handle(),
        &uuid.u,
        BleRemoteDeviceResource::on_service_discovered,
        device);
    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
  } else FAIL(INVALID_ARGUMENT);

  return process->null_object();
}

PRIMITIVE(discover_services_result) {
  ARGS(BleRemoteDeviceResource, device)

  int count = 0;
  for (auto service : device->services()) {
    if (service->is_returned()) continue;
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  int index = 0;
  for (auto service : device->services()) {
    if (service->is_returned()) continue;

    Array* service_info = process->object_heap()->allocate_array(2, process->null_object());
    if (service_info == null) FAIL(ALLOCATION_FAILED);

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) FAIL(ALLOCATION_FAILED);

    Error* err = null;
    ByteArray* uuid_byte_array = byte_array_from_uuid(process, service->uuid(), &err);
    if (err) return err;

    proxy->set_external_address(service);
    service_info->at_put(0, uuid_byte_array);
    service_info->at_put(1, proxy);
    array->at_put(index++, service_info);
  }

  for (auto service : device->services()) service->set_returned(true);

  return array;
}

PRIMITIVE(discover_characteristics){
  ARGS(BleServiceResource, service, Array, raw_characteristics_uuids)
  // NimBLE has a funny thing about descriptors (needed for subscriptions), where all characteristics
  // need to be discovered to discover descriptors. Therefore, we ignore the raw_characteristics_uuids
  // and always discover all, if they haven't been discovered yet.
  USE(raw_characteristics_uuids);
  if (!service->characteristics_discovered()) {
    int err = ble_gattc_disc_all_chrs(service->device()->handle(),
                                      service->start_handle(),
                                      service->end_handle(),
                                      BleServiceResource::on_characteristic_discovered,
                                      service);
    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
  } else {
    BleEventSource::instance()->on_event(service, kBleCharacteristicsDiscovered);
  }

  return process->null_object();
}

PRIMITIVE(discover_characteristics_result) {
  ARGS(BleServiceResource, service)

  int count = 0;
  for (auto characteristic : service->characteristics()) {
    if (characteristic->is_returned()) continue;
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  int index = 0;
  for (auto characteristic : service->characteristics()) {
    if (characteristic->is_returned()) continue;

    Array* characteristic_data = process->object_heap()->allocate_array(
        3, process->null_object());
    if (!characteristic_data) FAIL(ALLOCATION_FAILED);

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) FAIL(ALLOCATION_FAILED);

    proxy->set_external_address(characteristic);
    array->at_put(index++, characteristic_data);

    Error* err;
    ByteArray* uuid_byte_array = byte_array_from_uuid(process, characteristic->uuid(), &err);
    if (err) return err;

    characteristic_data->at_put(0, uuid_byte_array);
    characteristic_data->at_put(1, Smi::from(characteristic->properties()));
    characteristic_data->at_put(2, proxy);
  }

  for (auto characteristic : service->characteristics()) characteristic->set_returned(true);

  return array;
}

PRIMITIVE(discover_descriptors) {
  ARGS(BleCharacteristicResource, characteristic)
  // We always discover descriptors when discovering characteristics.
  BleEventSource::instance()->on_event(characteristic, kBleDescriptorsDiscovered);

  return process->null_object();
}

PRIMITIVE(discover_descriptors_result) {
  ARGS(BleCharacteristicResource, characteristic)

  int count = 0;
  for (auto descriptor : characteristic->descriptors()) {
    if (descriptor->is_returned()) continue;
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  int index = 0;
  for (auto descriptor : characteristic->descriptors()) {
    if (descriptor->is_returned()) continue;

    Array* descriptor_result = process->object_heap()->allocate_array(2, process->null_object());

    Error* err;
    ByteArray* uuid_byte_array = byte_array_from_uuid(process, descriptor->uuid(), &err);
    if (err) return err;

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) FAIL(ALLOCATION_FAILED);

    proxy->set_external_address(descriptor);

    descriptor_result->at_put(0, uuid_byte_array);
    descriptor_result->at_put(1, proxy);
    array->at_put(index++, descriptor_result);
  }

  for (auto descriptor : characteristic->descriptors()) descriptor->set_returned(true);

  return array;
}

PRIMITIVE(request_read) {
  ARGS(Resource, resource)

  auto element = reinterpret_cast<BleReadWriteElement*>(resource);

  if (!element->service()->device()) FAIL(INVALID_ARGUMENT);

  ble_gattc_read_long(element->service()->device()->handle(),
                      element->handle(),
                      0,
                      BleReadWriteElement::on_attribute_read,
                      element);

  return process->null_object();
}

PRIMITIVE(get_value) {
  ARGS(Resource, resource)
  Locker locker(BleResourceGroup::instance()->mutex());

  auto element = reinterpret_cast<BleReadWriteElement*>(resource);

  const os_mbuf* mbuf = element->mbuf_received();
  if (!mbuf) return process->null_object();

  Object* ret_val = convert_mbuf_to_heap_object(process, mbuf);
  if (!ret_val) FAIL(ALLOCATION_FAILED);

  element->set_mbuf_received(null);
  return ret_val;
}

PRIMITIVE(write_value) {
  ARGS(Resource, resource, Object, value, bool, with_response)

  auto element = reinterpret_cast<BleReadWriteElement*>(resource);

  if (!element->service()->device()) FAIL(INVALID_ARGUMENT);

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
        BleCharacteristicResource::on_write_response,
        element);
  } else {
    err = ble_gattc_write_no_rsp(
        element->service()->device()->handle(),
        element->handle(),
        om
    );
  }

  if (err != BLE_ERR_SUCCESS) {
    // The 'om' buffer is always consumed by the call to
    // ble_gattc_write_long() or ble_gattc_write_no_rsp()
    // regardless of the outcome.
    return nimble_stack_error(process, err);
  }

  return Smi::from(with_response ? 1 : 0);
}

/* Enables or disables notifications/indications for the characteristic value
 * of $characteristic. If $characteristic allows both, notifications will be used.
*/
PRIMITIVE(set_characteristic_notify) {
  ARGS(BleCharacteristicResource, characteristic, bool, enable)
  uint16 value = 0;

  if (enable) {
    if (characteristic->properties() & BLE_GATT_CHR_F_NOTIFY) {
      value = 1;
    } else if (characteristic->properties() & BLE_GATT_CHR_F_INDICATE) {
      value = 2;
    }
  }

  auto cccd = characteristic->find_cccd();
  if (!cccd) {
    FAIL(INVALID_ARGUMENT);
  } else {
    int err = ble_gattc_write_flat(
        characteristic->service()->device()->handle(),
        cccd->handle(),
        static_cast<void*>(&value), 2,
        BleCharacteristicResource::on_subscribe_response,
        characteristic);

    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
  }

  return process->null_object();
}

PRIMITIVE(advertise_start) {
  ARGS(BlePeripheralManagerResource, peripheral_manager, Blob, name, Array, service_classes,
       Blob, manufacturing_data, int, interval_us, int, conn_mode, int, flags)

  if (BlePeripheralManagerResource::is_advertising()) FAIL(ALREADY_EXISTS);

  // The advertisement packet.
  ble_hs_adv_fields fields{};
  // The size of the data that was already stored in the 'fields'.
  int advertisement_size = 0;
  // The scan response. Only used, if the advertising packet would become too big.
  ble_hs_adv_fields response_fields{};
  bool uses_scan_response = false;

  if (manufacturing_data.length() > 0) {
    int additional_size = 2 + manufacturing_data.length();
    ble_hs_adv_fields* target_fields = &fields;
    if (advertisement_size + additional_size > BLE_HS_ADV_MAX_SZ) {
      // Doesn't fit into the packet.
      // Store it in the scan response instead.
      target_fields = &response_fields;
      fields.mfg_data = null;
    } else {
      advertisement_size += additional_size;
    }
    target_fields->mfg_data = manufacturing_data.address();
    target_fields->mfg_data_len = manufacturing_data.length();
  }

  fields.flags = flags;
  advertisement_size += flags > 0 ? (2 + 1) : 0;

  ble_uuid16_t uuids_16[service_classes->length()];
  fields.uuids16 = uuids_16;
  fields.uuids16_is_complete = 1;
  ble_uuid32_t uuids_32[service_classes->length()];
  fields.uuids32 = uuids_32;
  fields.uuids32_is_complete = 1;
  ble_uuid128_t uuids_128[service_classes->length()];
  fields.uuids128 = uuids_128;
  fields.uuids128_is_complete = 1;
  ble_uuid16_t response_uuids_16[service_classes->length()];
  response_fields.uuids16 = response_uuids_16;
  response_fields.uuids16_is_complete = 1;
  ble_uuid32_t response_uuids_32[service_classes->length()];
  response_fields.uuids32 = response_uuids_32;
  response_fields.uuids32_is_complete = 1;
  ble_uuid128_t response_uuids_128[service_classes->length()];
  response_fields.uuids128 = response_uuids_128;
  response_fields.uuids128_is_complete = 1;
  for (int i = 0; i < service_classes->length(); i++) {
    Object* obj = service_classes->at(i);
    Blob blob;
    if (!obj->byte_content(process->program(), &blob, BlobKind::STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);

    ble_uuid_any_t uuid = uuid_from_blob(blob);
    if (uuid.u.type == BLE_UUID_TYPE_16) {
      // Make sure the additional UUID fits into the packet.
      // For the first UUID we also have to include the 2 byte header of the list.
      int additional_size = fields.num_uuids16 == 0 ? 4 : 2;
      ble_hs_adv_fields* target_fields = &fields;
      if (advertisement_size + additional_size > BLE_HS_ADV_MAX_SZ) {
        fields.uuids16_is_complete = 0;
        target_fields = &response_fields;
        uses_scan_response = true;
      } else {
        advertisement_size += additional_size;
      }
      const_cast<ble_uuid16_t*>(target_fields->uuids16)[target_fields->num_uuids16++] = uuid.u16;
    } else if (uuid.u.type == BLE_UUID_TYPE_32) {
      // Make sure the additional UUID fits into the packet.
      // For the first UUID we also have to include the 2 byte header of the list.
      int additional_size = fields.num_uuids32 == 0 ? 6 : 4;
      ble_hs_adv_fields* target_fields = &fields;
      if (advertisement_size + additional_size > BLE_HS_ADV_MAX_SZ) {
        fields.uuids32_is_complete = 0;
        target_fields = &response_fields;
        uses_scan_response = true;
      } else {
        advertisement_size += additional_size;
      }
      const_cast<ble_uuid32_t*>(target_fields->uuids32)[target_fields->num_uuids32++] = uuid.u32;
    } else {
      // Make sure the additional UUID fits into the packet.
      // For the first UUID we also have to include the 2 byte header of the list.
      int additional_size = fields.num_uuids128 == 0 ? 18 : 16;
      ble_hs_adv_fields* target_fields = &fields;
      if (advertisement_size + additional_size > BLE_HS_ADV_MAX_SZ) {
        fields.uuids128_is_complete = 0;
        target_fields = &response_fields;
        uses_scan_response = true;
      } else {
        advertisement_size += additional_size;
      }
       const_cast<ble_uuid128_t*>(target_fields->uuids128)[target_fields->num_uuids128++] = uuid.u128;
    }
  }

  if (name.length() > 0) {
    int additional_size = 2 + name.length();
    ble_hs_adv_fields* target_fields = &fields;
    if (advertisement_size + additional_size > BLE_HS_ADV_MAX_SZ) {
      // Without any name, there is no need to change the 'name_is_complete' field.
      // We could cut the name and send a part of it, but that's not necessary.
      fields.name = null;
      target_fields = &response_fields;
      uses_scan_response = true;
    } else {
      advertisement_size += additional_size;
    }
    target_fields->name = name.address();
    target_fields->name_len = name.length();
    target_fields->name_is_complete = 1;
  }

  int err = ble_gap_adv_set_fields(&fields);
  if (err != BLE_ERR_SUCCESS) {
    if (err == BLE_HS_EMSGSIZE) FAIL(OUT_OF_RANGE);
    return nimble_stack_error(process, err);
  }

  if (uses_scan_response) {
    err = ble_gap_adv_rsp_set_fields(&response_fields);
    if (err != BLE_ERR_SUCCESS) {
      if (err == BLE_HS_EMSGSIZE) FAIL(OUT_OF_RANGE);
      return nimble_stack_error(process, err);
    }
  }

  peripheral_manager->advertising_params().conn_mode = conn_mode;

  // TODO(anders): Be able to tune this.
  peripheral_manager->advertising_params().disc_mode = BLE_GAP_DISC_MODE_GEN;

  int advertising_interval = interval_us / 625;
  peripheral_manager->advertising_params().itvl_min = advertising_interval;
  peripheral_manager->advertising_params().itvl_max = advertising_interval;

  err = ble_gap_adv_start(
      BLE_OWN_ADDR_PUBLIC,
      null,
      BLE_HS_FOREVER,
      &peripheral_manager->advertising_params(),
      BlePeripheralManagerResource::on_gap,
      peripheral_manager);
  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }
  peripheral_manager->set_advertising_started(true);
  // nimble does not provide a advertise started gap event, so we just simulate the event
  // from the primitive.
  BleEventSource::instance()->on_event(peripheral_manager, kBleAdvertiseStartSucceeded);
  return process->null_object();
}

PRIMITIVE(advertise_stop) {
  ARGS(BlePeripheralManagerResource, peripheral_manager);
  if (BlePeripheralManagerResource::is_advertising()) {
    int err = ble_gap_adv_stop();
    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
  }
  peripheral_manager->set_advertising_started(false);

  return process->null_object();
}

PRIMITIVE(add_service) {
  ARGS(BlePeripheralManagerResource, peripheral_manager, Blob, uuid)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  ble_uuid_any_t ble_uuid = uuid_from_blob(uuid);

  BleServiceResource* service_resource =
      peripheral_manager->get_or_create_service_resource(ble_uuid, 0, 0);
  if (!service_resource) FAIL(MALLOC_FAILED);
  if (service_resource->deployed()) FAIL(INVALID_ARGUMENT);

  proxy->set_external_address(service_resource);
  return proxy;
}

PRIMITIVE(add_characteristic) {
  ARGS(BleServiceResource, service_resource, Blob, raw_uuid, int, properties,
       int, permissions, Object, value, int, read_timeout_ms)

  if (!service_resource->peripheral_manager()) {
    FAIL(INVALID_ARGUMENT);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (service_resource->deployed()) {
    FAIL(INVALID_ARGUMENT);
  }

  uint32 flags = properties & 0x7F;
  if (permissions & 0x1) {  // READ.
    uint32 mask = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_INDICATE;
    if ((properties & mask) == 0) {
      FAIL(INVALID_ARGUMENT);
    }
  }

  if (permissions & 0x2) { // WRITE.
    uint32 mask = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP;
    if ((properties & mask) == 0) {
      FAIL(INVALID_ARGUMENT);
    }
  }

  if (permissions & 0x4) { // READ_ENCRYPTED.
    uint32 mask = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_INDICATE;
    if ((properties & mask) == 0) {
      FAIL(INVALID_ARGUMENT);
    }
    flags |= BLE_GATT_CHR_F_READ_ENC;  // _ENC = Encrypted.
  }

  if (permissions & 0x8) { // WRITE_ENCRYPTED.
    uint32 mask = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP;
    if ((properties & mask) == 0) {
      FAIL(INVALID_ARGUMENT);
    }
    flags |= BLE_GATT_CHR_F_WRITE_ENC;  // _ENC = Encrypted.
  }

  ble_uuid_any_t ble_uuid = uuid_from_blob(raw_uuid);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  BleCharacteristicResource* characteristic =
    service_resource->get_or_create_characteristics_resource(ble_uuid, flags, 0, 0);

  if (!characteristic) {
    if (om != null) os_mbuf_free(om);
    FAIL(MALLOC_FAILED);
  }

  if (om != null) {
    characteristic->set_mbuf_to_send(om);
  } else {
    if (!characteristic->setup_callback_readable_characteristic(read_timeout_ms)) {
      delete characteristic;
      FAIL(MALLOC_FAILED);
    }
  }

  proxy->set_external_address(characteristic);
  return proxy;
}

PRIMITIVE(add_descriptor) {
  ARGS(BleCharacteristicResource, characteristic, Blob, raw_uuid, int, properties, int, permissions, Object, value)

  if (!characteristic->service()->peripheral_manager()) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  ble_uuid_any_t ble_uuid = uuid_from_blob(raw_uuid);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  uint8 flags = 0;
  if (permissions & 0x01 || properties & BLE_GATT_CHR_F_READ) flags |= BLE_ATT_F_READ;
  if (permissions & 0x02 || properties & (BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP)) flags |= BLE_ATT_F_WRITE;
  if (permissions & 0x04) flags |= BLE_ATT_F_READ_ENC; // _ENC = Encrypted.
  if (permissions & 0x08) flags |= BLE_ATT_F_WRITE_ENC; // _ENC = Encrypted.

  BleDescriptorResource* descriptor =
      characteristic->get_or_create_descriptor(ble_uuid, 0, flags, true);
  if (!descriptor) {
    if (om != null) os_mbuf_free(om);
    FAIL(MALLOC_FAILED);
  }

  if (om != null) descriptor->set_mbuf_to_send(om);

  proxy->set_external_address(descriptor);
  return proxy;
}

PRIMITIVE(deploy_service) {
  ARGS(BleServiceResource, service_resource)

  if (!service_resource->peripheral_manager()) FAIL(INVALID_ARGUMENT);
  if (service_resource->deployed()) FAIL(INVALID_ARGUMENT);

  int characteristic_count = 0;
  for (auto characteristic : service_resource->characteristics()) {
    USE(characteristic);
    characteristic_count++;
  }

  auto gatt_svr_chars = static_cast<ble_gatt_chr_def*>(calloc(characteristic_count + 1, sizeof(ble_gatt_chr_def)));
  if (!gatt_svr_chars) FAIL(MALLOC_FAILED);

  int characteristic_index = 0;
  for (auto characteristic : service_resource->characteristics()) {
    gatt_svr_chars[characteristic_index].uuid = characteristic->ptr_uuid();
    gatt_svr_chars[characteristic_index].access_cb = BleReadWriteElement::on_access;
    gatt_svr_chars[characteristic_index].arg = characteristic;
    gatt_svr_chars[characteristic_index].val_handle = characteristic->ptr_handle();
    gatt_svr_chars[characteristic_index].flags = characteristic->properties();

    int descriptor_count = 0;
    for (auto descriptor : characteristic->descriptors()) {
      USE(descriptor);
      descriptor_count++;
    }

    if (descriptor_count > 0) {
      auto gatt_desc_defs = static_cast<ble_gatt_dsc_def*>(calloc(descriptor_count + 1, sizeof(ble_gatt_dsc_def)));

      if (!gatt_desc_defs) {
        BleServiceResource::dispose_gatt_svr_chars(gatt_svr_chars, characteristic_index);
        FAIL(MALLOC_FAILED);
      }

      gatt_svr_chars[characteristic_index].descriptors = gatt_desc_defs;

      int descriptor_index = 0;
      for (auto descriptor : characteristic->descriptors()) {
        gatt_desc_defs[descriptor_index].uuid = descriptor->ptr_uuid();
        gatt_desc_defs[descriptor_index].att_flags = descriptor->properties();
        gatt_desc_defs[descriptor_index].access_cb = BleReadWriteElement::on_access;
        gatt_desc_defs[descriptor_index].arg = descriptor;
        descriptor_index++;
      }
    }
    characteristic_index++;
  }

  struct ble_gatt_svc_def gatt_svcs[2] = {
    {
      .type = BLE_GATT_SVC_TYPE_PRIMARY,
      .uuid = service_resource->ptr_uuid(),
      .includes = 0,
      .characteristics = gatt_svr_chars
    },
  };
  gatt_svcs[1].type = 0;

  int rc = ble_gatts_count_cfg(gatt_svcs);
  if (rc != BLE_ERR_SUCCESS) {
    BleServiceResource::dispose_gatt_svr_chars(gatt_svr_chars, characteristic_count);
    return nimble_stack_error(process, rc);
  }

  rc = ble_gatts_add_svcs(gatt_svcs);
  if (rc != BLE_ERR_SUCCESS) {
    BleServiceResource::dispose_gatt_svr_chars(gatt_svr_chars, characteristic_count);
    return nimble_stack_error(process, rc);
  }

  // TODO(kasper): Calling ble_gatts_start() multiple times without
  // resetting (and forgetting all registered services) is broken and
  // leads to memory corruption.
  //
  // We should avoid this by resetting, but that requires us to always
  // pass in the full list of services so we can recreate everything.
  //
  // See https://github.com/apache/mynewt-nimble/issues/556.
  rc = ble_gatts_start();
  if (rc != BLE_ERR_SUCCESS) {
    BleServiceResource::dispose_gatt_svr_chars(gatt_svr_chars, characteristic_count);
    return nimble_stack_error(process, rc);
  }

  // Mark the service resource as deployed by setting its characteristics.
  service_resource->set_svr_chars(gatt_svr_chars, characteristic_count);

  // NimBLE does not do async service deployments, so
  // simulate success event.
  BleEventSource::instance()->on_event(service_resource, kBleServiceAddSucceeded);
  return process->null_object();
}

PRIMITIVE(set_value) {
  ARGS(Resource, resource, Object, value)

  auto element = reinterpret_cast<BleReadWriteElement*>(resource);

  if (!element->service()->peripheral_manager()) FAIL(INVALID_ARGUMENT);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  element->set_mbuf_to_send(om);

  return process->null_object();
}

PRIMITIVE(get_subscribed_clients) {
  ARGS(BleCharacteristicResource, characteristic)
  int count = 0;
  for (auto subscription : characteristic->subscriptions()) {
    USE(subscription);
    count++;
  }

  Array* array = process->object_heap()->allocate_array(count, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  int index = 0;
  for (auto subscription : characteristic->subscriptions()) {
    array->at_put(index++, Smi::from(subscription->conn_handle()));
  }

  return array;
}

PRIMITIVE(notify_characteristics_value) {
  ARGS(BleCharacteristicResource, characteristic, uint16, conn_handle, Object, value)

  Subscription* subscription = null;
  for (auto sub : characteristic->subscriptions()) {
    if (sub->conn_handle() == conn_handle) {
      subscription = sub;
      break;
    }
  }

  if (!subscription) FAIL(INVALID_ARGUMENT);

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
    // The 'om' buffer is always consumed by the call to
    // ble_gattc_notify_custom() or ble_gattc_indicate_custom()
    // regardless of the outcome.
    return nimble_stack_error(process, err);
  }

  return process->null_object();
}

PRIMITIVE(get_att_mtu) {
  ARGS(Resource, resource)

  auto ble_resource = reinterpret_cast<BleResource*>(resource);

  uint16 mtu = BLE_ATT_MTU_DFLT;
  switch (ble_resource->kind()) {
    case BleResource::REMOTE_DEVICE: {
      auto device = reinterpret_cast<BleRemoteDeviceResource*>(ble_resource);
      mtu = ble_att_mtu(device->handle());
      break;
    }
    case BleResource::CHARACTERISTIC: {
      auto characteristic = reinterpret_cast<BleCharacteristicResource*>(ble_resource);
      int min_sub_mtu = -1;
      for (auto subscription : characteristic->subscriptions()) {
        uint16 sub_mtu = ble_att_mtu(subscription->conn_handle());
        min_sub_mtu = (min_sub_mtu == -1) ? sub_mtu : min(min_sub_mtu, sub_mtu);
      }
      if (min_sub_mtu != -1) mtu = min_sub_mtu;
      break;
    }
    default: {
      FAIL(INVALID_ARGUMENT);
    }
  }
  return Smi::from(mtu);
}

PRIMITIVE(set_preferred_mtu) {
  ARGS(int, mtu)
  if (mtu > BLE_ATT_MTU_MAX) FAIL(INVALID_ARGUMENT);

  int result = ble_att_set_preferred_mtu(mtu);

  if (result) {
    FAIL(INVALID_ARGUMENT);
  } else {
    return process->null_object();
  }
}

PRIMITIVE(get_error) {
  ARGS(Resource, resource)
  auto err_resource = reinterpret_cast<BleErrorCapableResource*>(resource);
  if (err_resource->error() == 0) FAIL(ERROR);

  return nimble_error_code_to_string(process, err_resource->error(), true);
}

PRIMITIVE(gc) {
  ARGS(Resource, resource)
  auto err_resource = reinterpret_cast<BleErrorCapableResource*>(resource);
  if (err_resource->has_malloc_error()) {
    err_resource->set_malloc_error(false);
    FAIL(CROSS_PROCESS_GC);
  }

  return process->null_object();
}

PRIMITIVE(read_request_reply) {
  ARGS(BleCharacteristicResource, characteristic, Object, value)

  os_mbuf* mbuf = null;
  Object* error = object_to_mbuf(process, value, &mbuf);
  if (error) return error;

  characteristic->handle_read_reply_request(mbuf);

  return process->null_object();
}

PRIMITIVE(get_bonded_peers) {
  ble_addr_t bonds[MYNEWT_VAL(BLE_STORE_MAX_BONDS)];
  int num_peers;
  ble_store_util_bonded_peers(bonds, &num_peers, MYNEWT_VAL(BLE_STORE_MAX_BONDS));

  Array* result = process->object_heap()->allocate_array(num_peers, process->null_object());
  for (int i = 0; i < num_peers; i++) {
    ByteArray* id = process->object_heap()->allocate_internal_byte_array(7);
    ByteArray::Bytes id_bytes(id);
    id_bytes.address()[0] = bonds[i].type;
    memcpy_reverse(id_bytes.address() + 1, bonds[i].val, 6);
    result->at_put(i, id);
  }

  return result;
}

} // namespace toit

#endif // defined(TOIT_FREERTOS) && defined(CONFIG_BT_ENABLED)
