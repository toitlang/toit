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

#if defined(TOIT_ESP32) && CONFIG_BT_ENABLED && CONFIG_BT_NIMBLE_ENABLED

#include <limits>

#include "../resource.h"
#include "../objects_inline.h"
#include "../resource_pool.h"
#include "../scheduler.h"
#include "../vm.h"

#include "../event_sources/ble_esp32.h"

#include <esp_bt.h>
#include <esp_log.h>
#include <nimble/nimble_port.h>
#include <host/ble_hs.h>
#undef min
#undef max
#include <host/util/util.h>
#include <host/ble_gap.h>
#include <services/gap/ble_svc_gap.h>
#include <services/gatt/ble_svc_gatt.h>
#include <store/config/ble_store_config.h>

namespace toit {

const int kInvalidBle = -1;
const int kInvalidHandle = UINT16_MAX;

// Only allow one instance of BLE running.
static ResourcePool<int, kInvalidBle> ble_pool(
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

static const uword kInvalidToken = std::numeric_limits<uword>::max() - 1;
static const uword kDeletedToken = std::numeric_limits<uword>::max();

/// A map from tokens to BleResources.
///
/// Since NimBLE runs on a separate thread we can have callbacks for resources
/// that have already been deleted. As such, we can't use pointers to our
/// objects as callback arguments. Instead we create tokens that we then
/// convert back to the actual BleResources (assuming they are still alive).
class TokenResourceMap {
 public:
  ~TokenResourceMap() {
    if (capacity != -1) {
      free(entries);
    }
  }

  // Returns false if there was a malloc error.
  bool add(BleResource* resource, uword* result);

  bool reserve_space();

  BleResource* get(uword token);

  void remove(uword token);

  /// Prunes deleted entries from the map.
  /// This operation should be done at opportune moments (at the end of
  /// deleting a Device object, for example).
  void compact(bool in_preparation_for_adding=false);

 private:
  static const int kInitialLength = 4;
  uword sequence_counter = 0;

  int find(word token) const;
  bool resize(int new_capacity);

  struct TokenResourceEntry {
    uword token;
    BleResource* resource;
  };
  // A sorted array of entries.
  TokenResourceEntry* entries;
  int length = 0;
  int capacity = -1;
};

// Returns false if there was a malloc error.
bool TokenResourceMap::add(BleResource* resource, uword* result) {
  if (!reserve_space()) return false;
  if (sequence_counter == kInvalidToken) FATAL("TokenResourceMap overflow");
  uword token = sequence_counter++;
  *result = token;
  TokenResourceEntry entry = {token, resource};
  entries[length++] = entry;
  return true;
}

bool TokenResourceMap::reserve_space() {
  if (capacity == -1) {
    entries = unvoid_cast<TokenResourceEntry*>(malloc(kInitialLength * sizeof(TokenResourceEntry)));
    if (!entries) return false;
    capacity = kInitialLength;
    length = 0;
  } else if (length == capacity) {
    // Try to purge deleted entries first.
    compact(true);
    // Only if that didn't work grow.
    if (length == capacity) {
      bool succeeded = resize(2 * capacity);
      if (!succeeded) return false;
    }
  }
  return true;
}

BleResource* TokenResourceMap::get(uword token) {
  int index = find(token);
  if (index == -1) return null;
  // Note that the resource could also be null.
  return entries[index].resource;
}

void TokenResourceMap::remove(uword token) {
  int index = find(token);
  if (index == -1) return;
  // Just mark the entry as removed.
  entries[index].resource = null;
}

/// Prunes deleted entries from the map.
/// This operation should be done at opportune moments (at the end of
/// deleting a Device object, for example).
void TokenResourceMap::compact(bool in_preparation_for_adding) {
  // Drop empty entries.
  int current = 0;
  for (int i = 0; i < length; i++) {
    if (entries[i].resource == null) {
      continue;
    }
    entries[current++] = entries[i];
  }
  if (length == current) return;

  length = current;

  // If no entries are left, delete the array.
  if (!in_preparation_for_adding && length == 0) {
    free(entries);
    entries = null;
    capacity = -1;
    length = 0;
  }
}

int TokenResourceMap::find(word token) const {
  // We can use the fact that the entries are sorted to do a binary search.
  // The token might not be in the table anymore.
  int left = 0;
  int right = length - 1;
  while (left <= right) {
    int middle = left + ((right - left) >> 1);
    if (entries[middle].token == token) return middle;
    if (entries[middle].token < token) {
      left = middle + 1;
    } else {
      right = middle - 1;
    }
  }
  return -1;
}

bool TokenResourceMap::resize(int new_capacity) {
  auto new_entries = unvoid_cast<TokenResourceEntry*>(realloc(entries, new_capacity * sizeof(TokenResourceEntry)));
  if (!new_entries) return false;
  entries = new_entries;
  capacity = new_capacity;
  return true;
}

class BleResourceGroup : public ResourceGroup {
 public:
  TAG(BleResourceGroup);
  BleResourceGroup(Process* process, BleEventSource* event_source, Mutex* mutex)
      : ResourceGroup(process, event_source)
      , mutex_(mutex) {}

  ~BleResourceGroup() override {
    OS::dispose(mutex_);
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

  TokenResourceMap token_resource_map;

  Mutex* mutex() const {
    return mutex_;
  }

 private:
  /// A mutex protecting BLE operations.
  /// NimBLE has its own thread, and we use this mutex to coordinate operations.
  Mutex* mutex_;
};

static BleResource* resource_for_token(void* o);

/// A scope for callbacks from the BLE thread.
/// Automatically takes the BLE mutex and releases it when the scope is destroyed.
/// Also allows to request a global GC.
class BleCallbackScope {
 public:
  BleCallbackScope();

  // Requests a global GC.
  // A callback is on a different thread and is thus allowed to request a multi-process GC.
  void gc() const {
    VM::current()->scheduler()->gc(null, /* malloc_failed = */ true, /* try_hard = */ true);
  }

  Locker locker;
};

class DiscoverableResource {
 public:
  DiscoverableResource() : returned_(false) {}
  bool is_returned() const { return returned_; }
  void set_returned(bool returned) { returned_ = returned; }

 private:
  bool returned_;
};

/// A class that can be used in a callback.
class BleCallbackResource : public BleResource {
 public:
  TAGS(BleCallbackResource);

  BleCallbackResource(ResourceGroup* group, Kind kind)
      : BleResource(group, kind)
      , malloc_error_(false)
      , error_(0) {}

  ~BleCallbackResource() {
    if (token_ != kDeletedToken) FATAL("token must be set to deleted");
  }

  bool has_malloc_error() const { return malloc_error_;}
  void set_malloc_error(bool malloc_error) { malloc_error_ = malloc_error; }
  int error() const { return error_; }
  void set_error(int error) { error_ = error; }


  void* token() const {
    if (token_ == kInvalidToken) FATAL("BleResource token wasn't set");
    if (token_ == kDeletedToken) FATAL("BleResource token taken for deleted object");
    return reinterpret_cast<void*>(token_);
  }

  /// Ensures that this resource has a token registered in the token-resource map.
  /// This function should be called before the resource is registered for a
  /// NimBLE callback.
  bool ensure_token() {
    if (token_ == kDeletedToken) FATAL("BleResource ensure token for deleted object");
    if (token_ == kInvalidToken) {
      uword token;
      bool succeeded = group()->token_resource_map.add(this, &token);
      if (!succeeded) return false;
      token_ = token;
    }
    return true;
  }

 protected:
  void delete_token() {
    Locker locker(group()->mutex());
    if (token_ != kInvalidToken && token_ != kDeletedToken) {
      group()->token_resource_map.remove(token_);
    }
    token_ = kDeletedToken;
  }

 private:
  bool malloc_error_;
  int error_;
  // The token we use for callbacks.
  uword token_ = kInvalidToken;
};

class BleReadWriteElement;

class ToitCallback {
 public:
  ToitCallback(int timeout_ms, Mutex* mutex, ConditionVariable* condition)
      : timeout_ms_(timeout_ms)
      , mutex_(mutex)
      , condition_(condition) {}

  ~ToitCallback() {
    OS::dispose(mutex_);
    OS::dispose(condition_);
  }

  bool is_pending_deletion() const { return pending_deletion_; }
  void mark_for_deletion() { pending_deletion_ = true; }
  int timeout_ms() const { return timeout_ms_; }

  bool needs_value() const { return state_ == WAITING_FOR_VALUE; }
  os_mbuf* value() const { return value_; }

  int call_toit(BleCallbackScope& scope,
                BleReadWriteElement* element,
                word request_kind,
                ble_gatt_access_ctxt* ctxt);

  /// The Toit code has produced a value.
  /// Make it available to the NimBLE thread.
  void handle_reply(os_mbuf* new_value);

  void delete_or_mark_for_deletion();

 private:
  // State relevant to the NimBLE thread.
  enum State {
    // No callback in progress.
    NO_CALLBACK,
    // Callback in progress. No value yet.
    WAITING_FOR_VALUE,
    // Callback in progress. Value has been set by the Toit callback.
    VALUE_PENDING,
    // Callback in progress. Toit callback has been canceled.
    CANCELED,
  };

  State state_ = NO_CALLBACK;
  bool pending_deletion_ = false;
  os_mbuf* value_ = null;
  int timeout_ms_;
  Mutex* mutex_;
  ConditionVariable* condition_;
};

class BleServiceResource;

class BleReadWriteElement : public BleCallbackResource {
 public:
  TAGS(BleReadWriteElement);

  BleReadWriteElement(ResourceGroup* group, Kind kind, const ble_uuid_any_t& uuid, uint16 handle)
      : BleCallbackResource(group, kind)
      , uuid_(uuid)
      , handle_(handle)
      , mbuf_received_(null)
      , mbuf_to_send_(null)
      , read_handler_(null)
      , write_handler_(null) {}

  ~BleReadWriteElement() override {
    if (mbuf_received_) os_mbuf_free_chain(mbuf_received_);
    if (mbuf_to_send_) os_mbuf_free(mbuf_to_send_);
    toit_callback_deinit(true);
    toit_callback_deinit(false);
  }

  ble_uuid_any_t &uuid() { return uuid_; }
  ble_uuid_t* ptr_uuid() { return &uuid_.u; }
  uint16 handle() const { return handle_; }
  uint16* ptr_handle() { return &handle_; }
  virtual BleServiceResource* service() = 0;

  // Sets received buffer to the new value.
  // Unless mbuf is null, this is done by the NimBLE thread.
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
    return mbuf_to_send_;
  }

  void set_mbuf_to_send(os_mbuf* mbuf) {
    if (mbuf_to_send_ != null) os_mbuf_free(mbuf_to_send_);
    mbuf_to_send_ = mbuf;
  }

  // Callback for when we receive a response from a remote device.
  // We requested to read an attribute, and are now getting called back.
  static int on_attribute_read(uint16_t conn_handle,
                               const ble_gatt_error* error,
                               ble_gatt_attr* attr,
                               void* arg) {
    USE(conn_handle);
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleReadWriteElement*>(resource)->_on_attribute_read(scope, error, attr);
    return BLE_ERR_SUCCESS;
  }

  // Callback for when this peripheral is accessed.
  static int on_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt* ctxt, void* arg) {
    USE(conn_handle);
    USE(attr_handle);
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback and cancel it.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    return static_cast<BleReadWriteElement*>(resource)->_on_access(scope, ctxt);
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

  bool toit_callback_needs_value(bool for_read) const;
  bool toit_callback_init(int timeout_ms, bool for_read);
  void toit_callback_deinit(bool for_read);
  void toit_callback_handle_reply(os_mbuf* mbuf, bool for_read);
  bool toit_callback_is_setup(bool for_read) const;

 protected:
  virtual bool marked_for_deletion() const = 0;

 private:
  void _on_attribute_read(const BleCallbackScope& scope, const ble_gatt_error* error, ble_gatt_attr* attr);
  int _on_access(BleCallbackScope& scope, ble_gatt_access_ctxt* ctxt);

  ble_uuid_any_t uuid_;
  uint16 handle_;
  os_mbuf* mbuf_received_;
  os_mbuf* mbuf_to_send_;
  ToitCallback* read_handler_;
  ToitCallback* write_handler_;
};

class BleDescriptorResource;
typedef DoubleLinkedList<BleDescriptorResource> DescriptorList;
class BleCharacteristicResource;

class BleDescriptorResource: public BleReadWriteElement, public DescriptorList::Element, public DiscoverableResource {
 public:
  TAG(BleDescriptorResource);
  BleDescriptorResource(ResourceGroup* group, BleCharacteristicResource* characteristic,
                        const ble_uuid_any_t& uuid, uint16 handle, int properties);

  ~BleDescriptorResource() override;

  BleServiceResource* service() override;
  uint8 properties() const { return properties_; }

  void delete_or_mark_for_deletion() override {
    delete_token();  // From now on, callbacks can't reach this instance.
    delete this;
  }

 protected:
  bool marked_for_deletion() const override {
    // Descriptors don't need to be marked for deletion, as they can always
    // get deleted immediately.
    return false;
  }

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
                            const ble_uuid_any_t& uuid, uint16 properties, uint16 handle,
                            uint16 definition_handle);

  ~BleCharacteristicResource() override;

  void delete_or_mark_for_deletion() override {
    if (marked_for_deletion_) return;
    delete_token();  // From now on, callbacks can't reach this instance.
    marked_for_deletion_ = true;
    clear_pending_descriptors();
    delete_if_able();
  }

  BleServiceResource* service() override { return service_; }

  uint16 properties() const { return properties_;  }
  uint16 definition_handle() const { return definition_handle_; }

  BleDescriptorResource* get_descriptor(const ble_uuid_any_t& uuid);
  BleDescriptorResource* get_or_create_descriptor(const BleCallbackScope* scope,
                                                  const ble_uuid_any_t& uuid, uint16_t handle,
                                                  uint8 properties);

  // Finds the Client Characteristic Configuration Descriptor.
  const BleDescriptorResource* find_cccd() {
    ble_uuid_any_t uuid;
    uuid.u16.u.type = BLE_UUID_TYPE_16;
    uuid.u16.value = BLE_GATT_DSC_CLT_CFG_UUID16; // UUID for Client Characteristic Configuration Descriptor.
    return get_descriptor(uuid);
  }

  // Called from the constructor of the BleDescriptorResource.
  void add_descriptor(BleDescriptorResource* descriptor) {
    descriptors_.append(descriptor);
  }

  // Called from the destructor of the BleDescriptorResource.
  void remove_descriptor(BleDescriptorResource* descriptor) {
    if (descriptors_.is_linked(descriptor)) {
      descriptors_.unlink(descriptor);
      delete_if_able();
    } else {
      // This could happen when we are clearing the pending descriptors, where
      // these entries are currently unlinked, but will be removed from the list.
      ASSERT(!descriptor->is_returned());
    }
  }

  DescriptorList& descriptors() {
    return descriptors_;
  }

  /// Clears descriptors that have not yet been returned to the user.
  /// During discovery, the 'descriptors_' list is used to store newly discovered
  /// services. As long as their 'returned' state is not set, they don't have a proxy
  /// yet.
  /// This can only happen for remote characteristics.
  void clear_pending_descriptors() {
    descriptors_.remove_wherever([&](BleDescriptorResource* descriptor) -> bool {
      if (descriptor->is_returned()) return false;
      group()->unregister_resource(descriptor);
      return true;
    });
  }

  bool update_subscription_status(const BleCallbackScope& scope, uint8_t indicate, uint8_t notify, uint16_t conn_handle);
  SubscriptionList& subscriptions() { return subscriptions_; }

  static int on_write_response(uint16_t conn_handle,
                               const ble_gatt_error* error,
                               ble_gatt_attr* attr,
                               void* arg) {
    USE(conn_handle);
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleCharacteristicResource*>(resource)->_on_write_response(scope, error, attr);
    return BLE_ERR_SUCCESS;
  }

  static int on_subscribe_response(uint16_t conn_handle,
                                  const ble_gatt_error* error,
                                  ble_gatt_attr* attr,
                                  void* arg) {
    USE(conn_handle);
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleCharacteristicResource*>(resource)->_on_subscribe_response(scope, error, attr);
    return BLE_ERR_SUCCESS;
  }

  uint16 get_mtu();

 protected:
  bool marked_for_deletion() const override {
    return marked_for_deletion_;
  }

 private:
  void delete_if_able() {
    if (marked_for_deletion_ && descriptors_.is_empty()) {
      delete this;
    }
  }
  void _on_write_response(const BleCallbackScope& scope, const ble_gatt_error* error, ble_gatt_attr* attr);
  void _on_subscribe_response(const BleCallbackScope& scope, const ble_gatt_error* error, ble_gatt_attr* attr);

  BleServiceResource* service_;
  uint16 properties_;
  uint16 definition_handle_;
  DescriptorList descriptors_;
  SubscriptionList subscriptions_;
  bool marked_for_deletion_ = false;
};

typedef DoubleLinkedList<BleServiceResource> ServiceResourceList;
class BleAdapterResource;
class BleRemoteDeviceResource;
class BlePeripheralManagerResource;

/// A service.
/// This class is used for remote services, and local services. If it is a remote service,
/// then the device_ field is set; otherwise the peripheral_manager_.
class BleServiceResource:
    public BleCallbackResource, public ServiceResourceList::Element, public DiscoverableResource {
 private:
  BleServiceResource(BleResourceGroup* group,
                     const ble_uuid_any_t& uuid, uint16 start_handle, uint16 end_handle)
      : BleCallbackResource(group, SERVICE)
      , uuid_(uuid)
      , start_handle_(start_handle)
      , end_handle_(end_handle)
      , characteristics_discovered_(false)
      , device_(null)
      , peripheral_manager_(null) {}

 public:
  TAG(BleServiceResource);
  BleServiceResource(BleResourceGroup* group, BleRemoteDeviceResource* device,
                     const ble_uuid_any_t& uuid, uint16 start_handle, uint16 end_handle);

  BleServiceResource(BleResourceGroup* group, BlePeripheralManagerResource* peripheral_manager,
                     const ble_uuid_any_t& uuid, uint16 start_handle, uint16 end_handle);

  ~BleServiceResource() override;

  /// Deletes this instance if no children are alive anymore.
  /// Otherwise marks this instance as deletable. Once all children are deleted
  /// we can then safely delete this instance as well.
  /// Relies on the fact that all children unregister themselves in their destructor.
  /// See 'delete_if_able'.
  void delete_or_mark_for_deletion() override {
    if (marked_for_deletion_) return;
    delete_token();  // From now on, callbacks can't reach this instance.
    // Clear the pending characteristics. We must be careful not to add any new ones
    // as there wouldn't be anything deleting them anymore.
    clear_pending_characteristics();
    marked_for_deletion_ = true;
    delete_if_able();
  }

  BleCharacteristicResource* get_characteristic(const ble_uuid_any_t& uuid);
  BleCharacteristicResource* get_or_create_characteristic(
      const BleCallbackScope* scope,
      const ble_uuid_any_t& uuid, uint16 properties, uint16 def_handle,
      uint16 value_handle);

  ble_uuid_any_t& uuid() { return uuid_; }
  ble_uuid_t* ptr_uuid() { return &uuid_.u; }
  uint16 start_handle() const { return start_handle_; }
  uint16 end_handle() const { return end_handle_; }

  BleRemoteDeviceResource* device() const { return device_; }
  BlePeripheralManagerResource* peripheral_manager() const { return peripheral_manager_; }
  CharacteristicResourceList& characteristics() { return characteristics_; }

  // Called from the constructor of the BleCharacteristicResource.
  void add_characteristic(BleCharacteristicResource* characteristic) {
    characteristics_.append(characteristic);
  }

  // Called from the destructor of the BleCharacteristicResource.
  void remove_characteristic(BleCharacteristicResource* characteristic) {
    if (characteristics_.is_linked(characteristic)) {
      characteristics_.unlink(characteristic);
      delete_if_able();
    } else {
      // This could happen when we are clearing the pending characteristics, where
      // these entries are currently unlinked, but will be removed from the list.
      ASSERT(!characteristic->is_returned());
    }
  }

  /// Clears characteristics that have not yet been returned to the user.
  /// During discovery, the 'characteristics_' list is used to store newly discovered
  /// characteristics. As long as their 'returned' state is not set, they don't have a proxy
  /// yet.
  /// This can only happen for remote characteristics (when the 'device_' field is set).
  void clear_pending_characteristics() {
    characteristics_.remove_wherever([&](BleCharacteristicResource* characteristic) -> bool {
      if (characteristic->is_returned()) return false;
      group()->unregister_resource(characteristic);
      return true;
    });
  }

  bool deployed() const { return deployed_; }

  void set_deployed(bool value) {
    deployed_ = value;
  }

  bool characteristics_discovered() const { return characteristics_discovered_; }
  void set_characteristics_discovered(bool discovered) { characteristics_discovered_ = discovered; }

  static int on_characteristic_discovered(uint16_t conn_handle,
                                          const ble_gatt_error* error,
                                          const ble_gatt_chr* chr, void* arg) {
    USE(conn_handle);
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleServiceResource*>(resource)->_on_characteristic_discovered(scope, error, chr);
    return BLE_ERR_SUCCESS;
  }

  static int on_descriptor_discovered(uint16_t conn_handle,
                                      const struct ble_gatt_error* error,
                                      uint16_t chr_val_handle,
                                      const struct ble_gatt_dsc* dsc,
                                      void* arg) {
    USE(conn_handle);
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleServiceResource*>(resource)->_on_descriptor_discovered(scope, error, dsc, chr_val_handle, false);
    return BLE_ERR_SUCCESS;
  }

  /// Disposes of the NimBLE data structure that is used for services.
  /// The data needs to be alive as long as the peripheral is running. It is therefore
  /// stored on the adapter instance.
  static void dispose_gatt_svcs(ble_gatt_svc_def* gatt_svcs) {
    ble_gatt_svc_def* cursor = gatt_svcs;
    while (cursor->type != 0) {
      dispose_gatt_svr_chars(const_cast<ble_gatt_chr_def*>(cursor->characteristics));
      cursor++;
    }
    free(gatt_svcs);
  }

  /// Disposes of the NimBLE data structure that is used for characteristics.
  static void dispose_gatt_svr_chars(ble_gatt_chr_def* gatt_svr_chars) {
    ble_gatt_chr_def* cursor = gatt_svr_chars;
    while (cursor->uuid != null) {
      free(cursor->descriptors);
      cursor++;
    }
    free(gatt_svr_chars);
  }

 private:
  void delete_if_able() {
    if (marked_for_deletion_ && characteristics_.is_empty()) {
      delete this;
    }
  }
  void _on_characteristic_discovered(const BleCallbackScope& scope, const ble_gatt_error* error, const ble_gatt_chr* chr);
  void _on_descriptor_discovered(const BleCallbackScope& scope,
                                 const struct ble_gatt_error* error,
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
  bool deployed_ = false;
  bool marked_for_deletion_ = false;
};

class BleCentralManagerResource : public BleCallbackResource {
 public:
  TAG(BleCentralManagerResource);

  explicit BleCentralManagerResource(BleResourceGroup* group, BleAdapterResource* adapter);

  /// Deletes the central manager resource.
  /// The resource may only get deleted when all children (devices) have been
  /// deleted as well.
  ~BleCentralManagerResource() override;

  static bool is_scanning() { return ble_gap_disc_active(); }

  DiscoveredPeripheral* get_discovered_peripheral() {
    return newly_discovered_peripherals_.first();
  }

  DiscoveredPeripheral* remove_discovered_peripheral() {
    return newly_discovered_peripherals_.remove_first();
  }

  static int on_discovery(ble_gap_event* event, void* arg) {
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleCentralManagerResource*>(resource)->_on_discovery(scope, event);
    return BLE_ERR_SUCCESS;
  }

  void increase_device_count() {
    device_count_++;
  }

  void decrease_device_count() {
    device_count_--;
    delete_if_able();
  }

  /// Deletes this instance if no children are alive anymore.
  /// Otherwise marks this instance as deletable. Once all children are deleted
  /// we can then safely delete this instance as well.
  /// Relies on the fact that all children unregister themselves in their destructor.
  /// See 'delete_if_able'.
  void delete_or_mark_for_deletion() override {
    delete_token();  // From now on, callbacks can't reach this instance.
    marked_for_deletion_ = true;
    delete_if_able();
  }

 private:
  void delete_if_able() {
    if (marked_for_deletion_ && device_count_ == 0) {
      delete this;
    }
  }

  void _on_discovery(const BleCallbackScope& scope, ble_gap_event* event);
  BleAdapterResource* adapter_;
  int device_count_ = 0;
  /// If true, then the central manager was closed, but wasn't deleted yet, because children
  /// are still alive.
  /// It will delete itself once all children have unregistered themselves.
  /// See 'delete_if_able'.
  bool marked_for_deletion_;
  /// A list of peripherals that have been discovered but that haven't been reported
  /// to the Toit program yet. These peripherals don't have any resources associated with
  /// them yet.
  DiscoveredPeripheralList newly_discovered_peripherals_;
};

template <typename T>
class ServiceContainer : public BleCallbackResource {
 public:
  ServiceContainer(BleResourceGroup* group, Kind kind)
      : BleCallbackResource(group, kind) {}

  // Called from the constructor of the BleServiceResource.
  void add_service(BleServiceResource* service) {
    services_.append(service);
  }

  // Called from the destructor of the BleServiceResource.
  void remove_service(BleServiceResource* service) {
    if (services_.is_linked(service)) {
      services_.unlink(service);
      delete_if_able();
    } else {
      // This can happen when being called through the 'clear_pending_services'.
      // In this case the service will be unlinked there.
      ASSERT(!service->is_returned());
    }
  }

  virtual T* type() = 0;
  BleServiceResource* get_service(const ble_uuid_any_t& uuid);
  BleServiceResource* get_or_create_service(const BleCallbackScope* scope,
                                            const ble_uuid_any_t& uuid, uint16 start, uint16 end);
  ServiceResourceList& services() { return services_; }

  /// Clears services that have not yet been returned to the user.
  /// During discovery, the 'services_' list is used to store newly discovered
  /// services. As long as their 'returned' state is not set, they don't have a proxy
  /// yet.
  /// This can only happen if the 'type()/T' is a BleRemoteDevice.
  void clear_pending_services() {
    services_.remove_wherever([&](BleServiceResource* service) -> bool {
      if (service->is_returned()) return false;
      group()->unregister_resource(service);
      return true;
    });
  }

 protected:
  bool has_services() {
    return !services_.is_empty();
  }
  virtual void delete_if_able() = 0;

 private:
  ServiceResourceList services_;
};

class BlePeripheralManagerResource : public ServiceContainer<BlePeripheralManagerResource> {
 public:
  TAG(BlePeripheralManagerResource);
  explicit BlePeripheralManagerResource(BleResourceGroup* group, BleAdapterResource* adapter);

  /// Deletes the peripheral manager resource.
  /// The resource may only get deleted when all children (services) have been
  /// deleted as well.
  ~BlePeripheralManagerResource() override;

  BlePeripheralManagerResource* type() override { return this; }

  void stop() {
    if (is_advertising()) {
      ble_gap_adv_stop();
    }
  }

  /// Whether advertising has been started by the user.
  /// The NimBLE stack stops advertising when a connection event occurs.
  /// For consistency with other platforms we restart the advertisement in such a case.
  bool advertising_started() const { return advertising_started_; }
  void set_advertising_started(bool advertising_started)  { advertising_started_ = advertising_started; }

  ble_gap_adv_params& advertising_params() { return advertising_params_; }

  static int on_gap(struct ble_gap_event* event, void* arg) {
    // NimBLE sends the notify/indicate transmission events synchronously from the
    // non-NimBLE stack. We thus can't take the lock here.
    // Since we don't use NOTIFY_TX events anyway, we just drop them.
    if (event->type == BLE_GAP_EVENT_NOTIFY_TX) return BLE_ERR_SUCCESS;

    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_SUCCESS;
    return static_cast<BlePeripheralManagerResource*>(resource)->_on_gap(scope, event);
  }
  static bool is_advertising() { return ble_gap_adv_active(); }

  /// Deletes this instance if no children (services) are alive anymore.
  /// Otherwise marks this instance as deletable. Once all children are deleted
  /// we can then safely delete this instance as well.
  /// Relies on the fact that all children unregister themselves in their destructor.
  /// See 'delete_if_able'.
  void delete_or_mark_for_deletion() override {
    delete_token();  // From now on, callbacks can't reach this instance.
    marked_for_deletion_ = true;
    stop();  // Always stop our activity, even if we can't fully shut down yet.
    delete_if_able();
  }

 protected:
  void delete_if_able() override {
    if (marked_for_deletion_ && !has_services()) {
      delete this;
    }
  }

 private:
  int _on_gap(const BleCallbackScope& scope, struct ble_gap_event* event);

  BleAdapterResource* adapter_;
  ble_gap_adv_params advertising_params_;
  bool advertising_started_;
  bool marked_for_deletion_;
};

class BleRemoteDeviceResource : public ServiceContainer<BleRemoteDeviceResource> {
 public:
  TAG(BleRemoteDeviceResource);
  explicit BleRemoteDeviceResource(BleResourceGroup* group, BleCentralManagerResource* central_manager, bool secure_connection)
      : ServiceContainer(group, REMOTE_DEVICE)
      , central_manager_(central_manager)
      , handle_(kInvalidHandle)
      , secure_connection_(secure_connection)
      , state_(DISCONNECTED) {
    central_manager_->increase_device_count();
  }

  ~BleRemoteDeviceResource() {
    central_manager_->decrease_device_count();
    group()->token_resource_map.compact();
  }

  BleRemoteDeviceResource* type() override { return this; }

  static int on_event(ble_gap_event* event, void* arg) {
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleRemoteDeviceResource*>(resource)->_on_event(scope, event);
    return BLE_ERR_SUCCESS;
  }

  static int on_service_discovered(uint16_t conn_handle,
                                   const struct ble_gatt_error* error,
                                   const struct ble_gatt_svc* service,
                                   void* arg) {
    BleCallbackScope scope;
    // If the resource has been deleted ignore the callback.
    BleResource* resource = resource_for_token(arg);
    if (resource == null) return BLE_ERR_OPERATION_CANCELLED;
    static_cast<BleRemoteDeviceResource*>(resource)->_on_service_discovered(scope, error, service);
    return BLE_ERR_SUCCESS;
  }

  uint16 handle() const { return handle_; }
  void set_handle(uint16 handle) { handle_ = handle; }

  int connect(uint8 own_addr_type, ble_addr_t* addr) {
    if (state_ == DELETABLE) return BLE_ERR_OPERATION_CANCELLED;  // Should never happen.
    // The 'connect' primitive ensured that the token is set.
    // NimBLE reports descriptive errors if we are already connecting or in another
    // bad state.
    int err = ble_gap_connect(own_addr_type, addr, 3000, null,
                              BleRemoteDeviceResource::on_event, token());
    if (err == BLE_ERR_SUCCESS) {
      state_ = CONNECTING;
    }
    return err;
  }

  int disconnect() {
    // Just try to disconnect, independently of the state we are currently in.
    int err = ble_gap_terminate(handle_, BLE_ERR_REM_USER_CONN_TERM);
    if (err == BLE_HS_ENOTCONN || (err & 0xFF) == BLE_ERR_CMD_DISALLOWED) {
      // We weren't actually connected.
      switch_to_state(DISCONNECTED);
      return BLE_ERR_SUCCESS;
    }
    return err;
  }

  uint16 get_mtu() {
    return ble_att_mtu(handle());
  }

  /// Deletes this instance if no children (services) are alive anymore.
  /// Otherwise marks this instance as deletable. Once all children are deleted
  /// we can then safely delete this instance as well.
  /// Relies on the fact that all children unregister themselves in their destructor.
  /// See 'delete_if_able'.
  void delete_or_mark_for_deletion() override {
    delete_token();  // From now on, callbacks can't reach this instance.
    state_ = DELETABLE;
    // Clears all services that haven't been given to the user yet.
    clear_pending_services();
    delete_if_able();
  }

  /// Whether this device is active.
  /// We ignore new services,... if we are not in an active state.
  bool is_connected() const {
    return state_ == CONNECTED;
  }

 protected:
  void delete_if_able() override {
    if (state_ == DELETABLE && !has_services()) {
      delete this;
    }
  }

 private:
  enum State {
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
    DISCONNECTED,
    DELETABLE,
  };
  void _on_event(const BleCallbackScope& scope, ble_gap_event* event);
  void _on_service_discovered(const BleCallbackScope& scope, const ble_gatt_error* error, const ble_gatt_svc* service);

  void switch_to_state(State new_state) {
    // Once we are marked for deletion, we don't care for any new state transitions anymore.
    if (state_ == DELETABLE) return;
    state_ = new_state;
  }

  BleCentralManagerResource* central_manager_;
  uint16 handle_;
  bool secure_connection_;
  State state_;
};

// The thread on the BleAdapterResource is responsible for running the nimble background thread.
// All events from the nimble background thread are delivered through callbacks to registered
// callback methods. The callback methods will then send the events to the EventSource to enable
// the normal resource state notification mechanism. This is
// done with the call BleEventSource::instance()->on_event(<resource>, <kBLE* event id>).
class BleAdapterResource : public BleResource, public Thread {
 public:
  TAG(BleAdapterResource);
  BleAdapterResource(ResourceGroup* group, int id)
      : BleResource(group, ADAPTER)
      , Thread("BLE")
      , id_(id)
      , state_(CREATED)
      , central_manager_(null)
      , peripheral_manager_(null) {
    // It is important to call nimble_port_init before starting the nimble
    // background thread that uses structures initialize by the init function.
    nimble_port_init();

    // The adapter creation is guaraded by the BLE pool (which only has one entry).
    // We can thus safely set the instance_ field.
    ASSERT(instance_ == null);
    instance_ = this;
    spawn(CONFIG_NIMBLE_TASK_STACK_SIZE);
  }

  /// Deletes the adapter resource.
  /// The resource may only get deleted when all children (central_manager and peripheral_manager)
  /// have been deleted as well.
  ~BleAdapterResource() override {
    // This function is called without the BLE lock being taken.

    ASSERT(central_manager_ == null && peripheral_manager_ == null);
    group()->token_resource_map.compact();

    // The `nimble_port_stop` will potentially post an event on the
    // toit-thread. However, contrary to all other callbacks, it will
    // wait for that callback to finish. This means, that we are not allowed
    // to hold the BLE lock when calling this function.
    FATAL_IF_NOT_ESP_OK(nimble_port_stop());

    // We still aren't allowed to take the lock, since the BLE thread needs to be
    // able to dispatch its last events.
    join();

    if (nimble_services_ != null) {
      BleServiceResource::dispose_gatt_svcs(nimble_services_);
    }

    nimble_port_deinit();

    ble_pool.put(id_);

    instance_ = null;
  }

  /// Deletes this instance if no children are alive anymore.
  /// Otherwise marks this instance as deletable. Once all children are deleted
  /// we can then safely delete this instance as well.
  /// Relies on the fact that all children unregister themselves in their destructor.
  /// See 'delete_if_able'.
  void delete_or_mark_for_deletion() override {
    state_ = CLOSED;
    delete_if_able();
  }

  bool is_closed() const {
    return state_ == CLOSED;
  }

  bool is_active() const {
    return state_ == ACTIVE;
  }

  bool started() const {
    return started_;
  }

  int start_peripheral() {
    ASSERT(!started());
    if (nimble_services_count_ == 0) return BLE_ERR_SUCCESS;

    int rc = ble_gatts_count_cfg(nimble_services_);
    if (rc != BLE_ERR_SUCCESS) return rc;

    rc = ble_gatts_add_svcs(nimble_services_);
    if (rc != BLE_ERR_SUCCESS) goto fail;

    rc = ble_gatts_start();
    if (rc != BLE_ERR_SUCCESS) goto fail;

    started_ = true;
    return BLE_ERR_SUCCESS;

    fail:
      // The 'stop' routine resets the NimBLE-internal "max" counts that were updated with
      // the 'ble_gatts_count_cfg' function. The 'stop' function has been added by Espressif and
      // is not part of the official NimBLE library.
      ble_gatts_stop();
      return rc;
  }

  /// Reserves space for 'count' services.
  /// Returns false if there was an allocation error.
  /// The peripheral must not yet have been deployed.
  /// If services were already reserved, disposes of the old services and
  /// creates a new backing store. This should not happen with normal use of the BLE library.
  bool reserve_services(int count) {
    ASSERT(!started());
    if (nimble_services_ != null) {
      BleServiceResource::dispose_gatt_svcs(nimble_services_);
      nimble_services_ = null;
      nimble_services_count_ = 0;
    }
    // We need to allocate one more entry for the "END" marker.
    static_assert(BLE_GATT_SVC_TYPE_END == 0, "Unexpected BLE_GATT_SVC_TYPE_END value");
    nimble_services_ = unvoid_cast<ble_gatt_svc_def*>(calloc(count + 1, sizeof(ble_gatt_svc_def)));
    if (!nimble_services_) return false;
    nimble_services_count_ = count;
    return true;
  }

  int services_capacity() const {
    return nimble_services_count_;
  }

  void store_nimble_service_definition(int index, const ble_gatt_svc_def& service_definition) {
    ASSERT(0 <= index && index < nimble_services_count_);
    nimble_services_[index] = service_definition;
  }

  // The BLE Host will notify when the BLE subsystem is synchronized. Before a successful sync, most
  // operation will not succeed.
  void on_sync(const BleCallbackScope& scope) {
    if (state_ != CREATED) return;
    state_ = ACTIVE;
    ble_gatts_reset();
    BleEventSource::instance()->on_event(this, kBleStarted);
  }

  BleCentralManagerResource* central_manager() {
    return central_manager_;
  }

  // Called in the constructor of the BleCentralManagerResource.
  void set_central_manager(BleCentralManagerResource* manager) {
    ASSERT(central_manager_ == null);
    central_manager_ = manager;
  }

  // Called in the destructor of the BleCentralManagerResource.
  void remove_central_manager(BleCentralManagerResource* manager) {
    ASSERT(central_manager_ == manager);
    central_manager_ = null;
    delete_if_able();
  }

  BlePeripheralManagerResource* peripheral_manager() {
    return peripheral_manager_;
  }

  // Called in the constructor of the BlePeripheralManagerResource.
  void set_peripheral_manager(BlePeripheralManagerResource* manager) {
    ASSERT(peripheral_manager_ == null);
    peripheral_manager_ = manager;
  }

  // Called in the destructor of the BlePeripheralManagerResource.
  void remove_peripheral_manager(BlePeripheralManagerResource* manager) {
    ASSERT(peripheral_manager_ == manager);
    peripheral_manager_ = null;
    delete_if_able();
  }

  /// Callback from the NimBLE thread when the underlying system has been initialized.
  /// Unlike all other NimBLE callbacks, we don't get any argument, so we have
  /// to use a static instance_ variable to deliver the event.
  static void on_sync();

  static BleAdapterResource* instance() {
    return instance_;
  }

 protected:
  void entry() override {
    nimble_port_run();
  }

 private:
  enum State {
    /// The adapter has been created, but the underlying system hasn't synchronized yet.
    /// At this stage most BLE calls wouldn't work.
    CREATED,
    /// The system has been initialized and can be used.
    ACTIVE,
    /// The adapter was closed, but wasn't deleted yet, because children are still alive.
    /// It will delete itself once all children have unregistered themselves.
    /// See 'delete_if_able'.
    CLOSED,
  };
  int id_;
  State state_;
  BleCentralManagerResource* central_manager_;
  BlePeripheralManagerResource* peripheral_manager_;
  ble_gatt_svc_def* nimble_services_ = null;
  int nimble_services_count_ = 0;
  /// Whether the peripheral (GATTS) has been started.
  bool started_ = false;

  static BleAdapterResource* instance_;

  void delete_if_able() {
    if (state_ == CLOSED && central_manager_ == null && peripheral_manager_ == null) {
      delete this;
    }
  }
};

// There can be only one active BleAdapterResource. This reference will be
// active when the adapter exists.
BleAdapterResource* BleAdapterResource::instance_ = null;

static BleResource* resource_for_token(void* o) {
  auto instance = BleAdapterResource::instance();
  if (instance == null) return null;
  return instance->group()->token_resource_map.get(unvoid_cast<uword>(o));
}

Object* nimble_error_code_to_string(Process* process, int error_code, bool host) {
  String* str;
  if (host && error_code == BLE_HS_ENOTCONN) {
    str = process->allocate_string("NimBLE error, Type: host, error code: 0x07. No open connection");
  } else {
    static const size_t BUFFER_LEN = 400;
    char buffer[BUFFER_LEN];
    const char* gist = "https://gist.github.com/mikkeldamsgaard/0857ce6a8b073a52d6f07973a441ad54";
    int length = snprintf(buffer, BUFFER_LEN, "NimBLE error, Type: %s, error code: 0x%02x. See %s",
                          host ? "host" : "client",
                          error_code % 0x100,
                          gist);
    str = process->allocate_string(buffer, length);
  }
  if (!str) FAIL(ALLOCATION_FAILED);
  return Primitive::mark_as_error(str);
}

static Object* nimble_stack_error(Process* process, int error_code) {
  return nimble_error_code_to_string(process, error_code, false);
}

Object* nimble_host_stack_error(Process* process, int error_code) {
  return nimble_error_code_to_string(process, error_code, true);
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

static ByteArray* byte_array_from_uuid(Process* process, const ble_uuid_any_t& uuid, Error** err) {
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

static bool uuid_equals(const ble_uuid_any_t& uuid, const ble_uuid_any_t& other) {
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

BleCallbackScope::BleCallbackScope()
    : locker(BleAdapterResource::instance()->group()->mutex()) {}

uint32_t BleResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  USE(resource);
  state |= data;
  return state;
}

BleDescriptorResource::BleDescriptorResource(ResourceGroup* group,
                                             BleCharacteristicResource* characteristic,
                                             const ble_uuid_any_t& uuid, uint16 handle, int properties)
    : BleReadWriteElement(group, DESCRIPTOR, uuid, handle)
    , characteristic_(characteristic)
    , properties_(properties) {
  characteristic->add_descriptor(this);
}


BleDescriptorResource::~BleDescriptorResource() {
  characteristic_->remove_descriptor(this);
}

BleServiceResource* BleDescriptorResource::service() {
  return characteristic_->service();
}

BleCharacteristicResource::BleCharacteristicResource(BleResourceGroup* group, BleServiceResource* service,
                                                     const ble_uuid_any_t& uuid, uint16 properties, uint16 handle,
                                                     uint16 definition_handle)
    : BleReadWriteElement(group, CHARACTERISTIC, uuid, handle)
    , service_(service)
    , properties_(properties)
    , definition_handle_(definition_handle) {
  service->add_characteristic(this);
}

BleCharacteristicResource::~BleCharacteristicResource() {
  while (!subscriptions_.is_empty()) {
    auto subscription = subscriptions_.remove_first();
    delete subscription;
  }
  service_->remove_characteristic(this);
}

uint16 BleCharacteristicResource::get_mtu() {
  int min_sub_mtu = -1;
  for (auto subscription : subscriptions()) {
    uint16 sub_mtu = ble_att_mtu(subscription->conn_handle());
    if (min_sub_mtu == -1) min_sub_mtu = sub_mtu;
    else min_sub_mtu = Utils::min(min_sub_mtu, static_cast<int>(sub_mtu));
  }
  if (min_sub_mtu != -1) return min_sub_mtu;
  return service()->device()->get_mtu();
}

BleServiceResource::BleServiceResource(BleResourceGroup* group, BleRemoteDeviceResource* device,
                                       const ble_uuid_any_t& uuid, uint16 start_handle, uint16 end_handle)
    : BleServiceResource(group, uuid, start_handle, end_handle) {
  device_ = device;
  device->add_service(this);
}

BleServiceResource::BleServiceResource(BleResourceGroup* group, BlePeripheralManagerResource* peripheral_manager,
                                       const ble_uuid_any_t& uuid, uint16 start_handle, uint16 end_handle)
    : BleServiceResource(group, uuid, start_handle, end_handle) {
  peripheral_manager_ = peripheral_manager;
  peripheral_manager->add_service(this);
}

BleServiceResource::~BleServiceResource() {
  // TODO(florian): this is completely wrong: the gatt_svcs_ must be kept alive
  // as long as the gatt server is running. Since there isn't any way to
  // stop the gatt server, this means that the data should be stored on the adapter.
  // Only when that one shuts down can we dispose of the data.
  if (peripheral_manager_ != null) {
    peripheral_manager_->remove_service(this);
  } else {
    device_->remove_service(this);
  }
}

template<typename T>
BleServiceResource*
ServiceContainer<T>::get_service(const ble_uuid_any_t& uuid) {
  for (auto service : services_) {
    if (uuid_equals(uuid, service->uuid())) return service;
  }
  return null;
}

template<typename T>
BleServiceResource*
ServiceContainer<T>::get_or_create_service(const BleCallbackScope* scope,
                                           const ble_uuid_any_t& uuid, uint16 start, uint16 end) {
  auto service = get_service(uuid);
  if (service) {
    if (service->start_handle() != start || service->end_handle() != end) {
      ESP_LOGW("BLE", "Service changed handles");
    }
    return service;
  }
  service = _new BleServiceResource(group(), type(), uuid, start,end);
  if (!service && scope) {
    // Since this method is called from the BLE event handler and there is no
    // toit code monitoring the interaction, we resort to calling gc by hand to
    // try to recover on OOM.
    scope->gc();
    service = _new BleServiceResource(group(), type(), uuid, start,end);
  }
  if (!service) return null;
  group()->register_resource(service);
  return service;
}

void
BleServiceResource::_on_characteristic_discovered(const BleCallbackScope& scope, const struct ble_gatt_error* error, const struct ble_gatt_chr* chr) {
  switch (error->status) {
    case 0: {
      if (has_malloc_error()) return;

      auto ble_characteristic =
          get_or_create_characteristic(&scope,
                                       chr->uuid, chr->properties, chr->def_handle,
                                       chr->val_handle);
      if (!ble_characteristic) {
        set_malloc_error(true);
        clear_pending_characteristics();
      }
      break;
    }
    case BLE_HS_EDONE: // No more characteristics can be discovered.
      if (has_malloc_error()) {
        clear_pending_characteristics();
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        ble_gattc_disc_all_dscs(device()->handle(),
                                start_handle(),
                                end_handle(),
                                BleServiceResource::on_descriptor_discovered,
                                token());
      }
      break;
    default:
      clear_pending_characteristics();
      if (has_malloc_error()) {
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        set_error(error->status);
        BleEventSource::instance()->on_event(this, kBleDiscoverOperationFailed);
      }
      break;

  }
}

BleCharacteristicResource* BleServiceResource::get_characteristic(const ble_uuid_any_t& uuid) {
  for (auto characteristic : characteristics_) {
    if (uuid_equals(uuid, characteristic->uuid())) return characteristic;
  }
  return null;
}

BleCharacteristicResource* BleServiceResource::get_or_create_characteristic(
    const BleCallbackScope* scope,
    const ble_uuid_any_t& uuid, uint16 properties, uint16 def_handle,
    uint16 value_handle) {
  auto characteristic = get_characteristic(uuid);
  if (characteristic != null ) {
    if (characteristic->properties() != properties ||
        characteristic->definition_handle() != def_handle ||
        characteristic->handle() != value_handle) {
      ESP_LOGW("BLE", "Characteristic changed");
    }
  }
  characteristic = _new BleCharacteristicResource(group(), this, uuid, properties, value_handle, def_handle);
  if (!characteristic && scope) {
    // Since this method is called from the BLE event handler and there is no
    // toit code monitoring the interaction, we resort to calling gc by hand to
    // try to recover on OOM.
    scope->gc();
    characteristic = _new BleCharacteristicResource(group(), this, uuid, properties, value_handle, def_handle);
  }
  if (!characteristic) return null;
  group()->register_resource(characteristic);
  return characteristic;
}

BleCentralManagerResource::BleCentralManagerResource(BleResourceGroup* group,
                                                     BleAdapterResource* adapter)
    : BleCallbackResource(group, CENTRAL_MANAGER)
    , adapter_(adapter)
    , marked_for_deletion_(false) {
  adapter_->set_central_manager(this);
}

BleCentralManagerResource::~BleCentralManagerResource() {
  if (is_scanning()) {
    int err = ble_gap_disc_cancel();
    if (err != BLE_ERR_SUCCESS && err != BLE_HS_EALREADY) {
      ESP_LOGE("BLE", "Failed to cancel discovery");
    }
  }

  while (auto peripheral = remove_discovered_peripheral()) {
    delete peripheral;
  }

  adapter_->remove_central_manager(this);
  group()->token_resource_map.compact();
}

void BleCentralManagerResource::_on_discovery(const BleCallbackScope& scope, ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_DISC_COMPLETE:
      BleEventSource::instance()->on_event(this, kBleCompleted);
      break;
    case BLE_GAP_EVENT_DISC: {
      uint8* data = null;
      uint8 data_length = event->disc.length_data;
      if (data_length > 0) {
        data = unvoid_cast<uint8*>(malloc(data_length));
        if (!data) {
          // Since this method is called from the BLE event handler and there is no
          // toit code monitoring the interaction, we resort to calling gc by hand to
          // try to recover on OOM.
          scope.gc();
          data = unvoid_cast<uint8*>(malloc(data_length));
          if (!data) {
            set_malloc_error(true);
            BleEventSource::instance()->on_event(this, kBleMallocFailed);
            return;
          }
        }
        memmove(data, event->disc.data, data_length);
      }

      auto discovered_peripheral = _new DiscoveredPeripheral(
          event->disc.addr, event->disc.rssi, data, data_length, event->disc.event_type);

      if (!discovered_peripheral) {
        // Same as for the data above: do a GC on the BLE thread.
        scope.gc();
        discovered_peripheral = _new DiscoveredPeripheral(
            event->disc.addr, event->disc.rssi, data, data_length, event->disc.event_type);
        if (!discovered_peripheral) {
          if (data) free(data);
          set_malloc_error(true);
          BleEventSource::instance()->on_event(this, kBleMallocFailed);
          return;
        }
      }

      newly_discovered_peripherals_.append(discovered_peripheral);

      BleEventSource::instance()->on_event(this, kBleDiscovery);
    }
  }
}

BlePeripheralManagerResource::BlePeripheralManagerResource(BleResourceGroup* group,
                                                           BleAdapterResource* adapter)
    : ServiceContainer(group, PERIPHERAL_MANAGER)
    , adapter_(adapter)
    , advertising_params_({})
    , advertising_started_(false)
    , marked_for_deletion_(false) {
  adapter_->set_peripheral_manager(this);
}

BlePeripheralManagerResource::~BlePeripheralManagerResource() {
  stop();
  adapter_->remove_peripheral_manager(this);
  group()->token_resource_map.compact();
}

void BleRemoteDeviceResource::_on_event(const BleCallbackScope& scope, ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (event->connect.status == 0) {
        ASSERT(handle() == kInvalidHandle)
        set_handle(event->connect.conn_handle);
        // TODO(mikkel): Expose this as a primitive.
        ble_gattc_exchange_mtu(event->connect.conn_handle, null, null);
        switch_to_state(CONNECTED);
      } else {
        BleEventSource::instance()->on_event(this, kBleConnectFailed);
        switch_to_state(DISCONNECTED);
      }
      break;
    case BLE_GAP_EVENT_DISCONNECT:
      BleEventSource::instance()->on_event(this, kBleDisconnected);
      switch_to_state(DISCONNECTED);
      break;
    case BLE_GAP_EVENT_NOTIFY_RX:
      // Notify/indicate update.

      // TODO(mikkel): More efficient data structure.
      for (auto service: services()) {
        for (auto characteristic: service->characteristics()) {
          if (characteristic->handle() == event->notify_rx.attr_handle) {
            characteristic->set_mbuf_received(event->notify_rx.om);
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
        switch_to_state(CONNECTED);
      }
      break;
    case BLE_GAP_EVENT_ENC_CHANGE:
      if (secure_connection_) {
        BleEventSource::instance()->on_event(this, kBleConnected);
        switch_to_state(CONNECTED);
      }
      break;
  }
}

void BleRemoteDeviceResource::_on_service_discovered(const BleCallbackScope& scope, const ble_gatt_error* error, const ble_gatt_svc* service) {
  switch (error->status) {
    case 0: {
      if (has_malloc_error()) return;

      if (is_connected()) {
        auto ble_service = get_or_create_service(&scope, service->uuid, service->start_handle, service->end_handle);
        if (!ble_service) {
          set_malloc_error(true);
          clear_pending_services();
        }
      }
      break;
    }
    case BLE_HS_EDONE: // No more services can be discovered.
      if (has_malloc_error()) {
        clear_pending_services();
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        BleEventSource::instance()->on_event(this, kBleServicesDiscovered);
      }
      break;
    default:
      clear_pending_services();
      if (has_malloc_error()) {
        BleEventSource::instance()->on_event(this, kBleMallocFailed);
      } else {
        set_error(error->status);
        BleEventSource::instance()->on_event(this, kBleDiscoverOperationFailed);
      }
      break;
  }
}

BleDescriptorResource* BleCharacteristicResource::get_descriptor(const ble_uuid_any_t& uuid) {
  for (auto descriptor : descriptors_) {
    if (uuid_equals(uuid, descriptor->uuid())) return descriptor;
  }
  return null;
}

BleDescriptorResource* BleCharacteristicResource::get_or_create_descriptor(const BleCallbackScope* scope,
                                                                           const ble_uuid_any_t& uuid, uint16_t handle, uint8 properties) {
  auto descriptor = get_descriptor(uuid);
  if (descriptor) {
    if (descriptor->handle() != handle || descriptor->properties() != properties) {
      ESP_LOGW("BLE", "Descriptor changed handle or properties");
    }
    return descriptor;
  }

  descriptor = _new BleDescriptorResource(group(), this, uuid, handle, properties);
  if (!descriptor && scope) {
    // Since this method is called from the BLE event handler and there is no
    // toit code monitoring the interaction, we resort to calling gc by hand to
    // try to recover on OOM.
    scope->gc();
    descriptor = _new BleDescriptorResource(group(), this, uuid, handle, properties);
  }
  if (!descriptor) return null;
  group()->register_resource(descriptor);
  return descriptor;
}

int ToitCallback::call_toit(BleCallbackScope& scope,
                             BleReadWriteElement* element,
                             word request_kind,
                             ble_gatt_access_ctxt* ctxt) {
  ASSERT(state_ == NO_CALLBACK);
  // Signal a pending handler (if one exists) that it should produce data.
  BleEventSource::instance()->on_event(element, request_kind);
  state_ = WAITING_FOR_VALUE;
  { Unlocker unlocker(scope.locker);
    Locker locker(mutex_);
    // Wait for the value, or the timeout.
    // Due to the unlocker other BLE calls are allowed, but they might
    // be blocked by us (the NimBLE thread) being stuck here. Due to the timeout,
    // this can only be temporary.
    OS::wait_us(condition_, 1000 * timeout_ms_);
  }
  int result = BLE_ERR_SUCCESS;
  switch (state_) {
    case NO_CALLBACK:
      UNREACHABLE();
    case WAITING_FOR_VALUE:
      // The timeout triggered without any value.
      result = BLE_ERR_OPERATION_CANCELLED;
      break;
    case VALUE_PENDING:
      if (value_ != null) {
        result = os_mbuf_appendfrom(ctxt->om,
                                    value_,
                                    0,
                                    BleReadWriteElement::mbuf_total_len(value_));
        os_mbuf_free(value_);
        value_ = null;
      } else {
        // Empty response. Do nothing (but return with BLE_ERR_SUCCESS).
      }
      break;
    case CANCELED:
      result = BLE_ERR_OPERATION_CANCELLED;
      break;
  }
  if (pending_deletion_) {
    delete this;
  }
  return result;
}

void ToitCallback::delete_or_mark_for_deletion() {
  if (pending_deletion_) return;
  switch (state_) {
    case NO_CALLBACK:
      delete this;
      return;
    case WAITING_FOR_VALUE:
      // Since a request is in progress, we can't delete the mutex and condition variable yet.
      // We have to let the NimBLE thread do that. We need to wake the thread, though.
      state_ = CANCELED;
      pending_deletion_ = true;
      { Locker callback_locker(mutex_);
        OS::signal_all(condition_);
      }
      break;
    case VALUE_PENDING:
    case CANCELED:
      // We don't need to signal the NimBLE thread anymore, but we need to
      // mark ourselves.
      pending_deletion_ = true;
      break;
  }
}

void ToitCallback::handle_reply(os_mbuf* new_value) {
  ASSERT(value_ == null);
  ASSERT(needs_value());
  value_ = new_value;
  state_ = VALUE_PENDING;
  Locker callback_locker(mutex_);
  OS::signal_all(condition_);
}

bool BleReadWriteElement::toit_callback_needs_value(bool for_read) const {
  auto handler = for_read ? read_handler_ : write_handler_;
  return handler != null && handler->needs_value();
}

bool BleReadWriteElement::toit_callback_init(int timeout_ms, bool for_read) {
  auto handler = for_read ? read_handler_ : write_handler_;
  ASSERT(handler == null);
  auto mutex = OS::allocate_mutex(1, for_read ? "Read request" : "Write request");
  if (!mutex) return false;
  auto condition = OS::allocate_condition_variable(mutex);
  if (!condition) {
    OS::dispose(mutex);
    return false;
  }
  auto callback = _new ToitCallback(timeout_ms, mutex, condition);
  if (!callback) {
    OS::dispose(condition);
    OS::dispose(mutex);
    return false;
  }
  if (for_read) {
    read_handler_ = callback;
  } else {
    write_handler_ = callback;
  }
  return true;
}

void BleReadWriteElement::toit_callback_deinit(bool for_read) {
  if (for_read) {
    if (read_handler_ == null) return;
    read_handler_->delete_or_mark_for_deletion();
    read_handler_ = null;
  } else {
    if (write_handler_ == null) return;
    write_handler_->delete_or_mark_for_deletion();
    write_handler_ = null;
  }
}

/// The Toit code gave us a value for the request.
/// Signal the NimBLE thread that it should use it.
void BleReadWriteElement::toit_callback_handle_reply(os_mbuf* mbuf, bool for_read) {
  auto handler = for_read ? read_handler_ : write_handler_;
  handler->handle_reply(mbuf);
}

bool BleReadWriteElement::toit_callback_is_setup(bool for_read) const {
  auto handler = for_read ? read_handler_ : write_handler_;
  return handler != null;
}

void BleReadWriteElement::_on_attribute_read(const BleCallbackScope& scope,
                                             const struct ble_gatt_error* error,
                                             struct ble_gatt_attr* attr) {
  switch (error->status) {
    case 0: {
      set_mbuf_received(attr->om);
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

int BleReadWriteElement::_on_access(BleCallbackScope& scope, ble_gatt_access_ctxt* ctxt) {
  switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
    case BLE_GATT_ACCESS_OP_READ_DSC: {
      auto callback = read_handler_;
      if (callback == null) {
        if (mbuf_to_send() != null) {
          return os_mbuf_appendfrom(ctxt->om, mbuf_to_send(), 0, mbuf_total_len(mbuf_to_send_));
        } else {
          // Complete without data.
          return BLE_ERR_SUCCESS;
        }
      } else {
        // Note that 'call_toit' will release the BLE lock.
        // It is thus unsafe to use 'this' after the call, as this instance might have
        // been deleted in the meantime.
        return callback->call_toit(scope, this, kBleDataReadRequest, ctxt);
      }
      break;
    }
    case BLE_GATT_ACCESS_OP_WRITE_CHR:
    case BLE_GATT_ACCESS_OP_WRITE_DSC: {
      set_mbuf_received(ctxt->om);
      ctxt->om = null;
      auto callback = write_handler_;
      if (callback == null) {
        // Notify any 'read' function that there is data.
        BleEventSource::instance()->on_event(this, kBleDataReceived);
      } else {
        // Note that 'call_toit' will release the BLE lock.
        // It is thus unsafe to use 'this' after the call, as this instance might have
        // been deleted in the meantime.
        return callback->call_toit(scope, this, kBleDataWriteRequest, ctxt);
      }
      break;
    }
    default:
      // Unhandled event, no dispatching.
      return 0;
  }
  return BLE_ERR_SUCCESS;
}

void BleCharacteristicResource::_on_write_response(const BleCallbackScope& scope,
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

void BleCharacteristicResource::_on_subscribe_response(const BleCallbackScope& scope,
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
BleServiceResource::_on_descriptor_discovered(const BleCallbackScope& scope,
                                              const struct ble_gatt_error* error, const struct ble_gatt_dsc* dsc,
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
      auto descriptor = characteristic->get_or_create_descriptor(&scope, dsc->uuid, dsc->handle, 0);
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

bool BleCharacteristicResource::update_subscription_status(const BleCallbackScope& scope,
                                                           uint8_t indicate,
                                                           uint8_t notify,
                                                           uint16_t conn_handle) {
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
    scope.gc();
    subscription = _new Subscription(indicate, notify, conn_handle);
    if (!subscription) return false;
  }

  subscriptions_.append(subscription);
  return true;
}

static int do_start_advertising(BlePeripheralManagerResource* peripheral_manager) {
  // The advertise_start primitive ensured that the token is set.
  return ble_gap_adv_start(
      BLE_OWN_ADDR_PUBLIC,
      null,
      BLE_HS_FOREVER,
      &peripheral_manager->advertising_params(),
      BlePeripheralManagerResource::on_gap,
      peripheral_manager->token());
}

int BlePeripheralManagerResource::_on_gap(const BleCallbackScope& scope, struct ble_gap_event* event) {
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (advertising_started()) {
        // NimBLE stops advertising on connection event. To keep the library consistent
        // with other platforms the advertising is restarted.
        int err = do_start_advertising(this);
        if (err != BLE_ERR_SUCCESS && err != BLE_HS_ENOMEM) {
          ESP_LOGW("BLE", "Could not restart advertising: err=%d", err);
        }
      }
      break;
    case BLE_GAP_EVENT_DISCONNECT:
      if (advertising_started() && !ble_gap_adv_active()) {
        int err = do_start_advertising(this);
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
            bool success = characteristic->update_subscription_status(scope,
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

static Object* blob_to_mbuf(Process* process, Blob& bytes, os_mbuf** result) {
  *result = null;
  if (bytes.length() > 0) {
    os_mbuf* mbuf = ble_hs_mbuf_from_flat(bytes.address(), bytes.length());
    // A null response is not an allocation error, as the mbufs are allocated on boot based on configuration settings.
    // Therefore, a GC will do little to help the situation and will eventually result in the VM thinking it is out of memory.
    // The mbuf will be freed eventually by the NimBLE stack. The client code will
    // have to wait and then try again.
    if (!mbuf) FAIL(QUOTA_EXCEEDED);
    *result = mbuf;
  }
  return null;  // No error.
}


static Object* object_to_mbuf(Process* process, Object* object, os_mbuf** result) {
  *result = null;
  if (object == process->null_object()) return null;
  Blob bytes;
  if (!object->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_BYTES_TYPE);
  return blob_to_mbuf(process, bytes, result);
}

void BleAdapterResource::on_sync() {
  // Make sure we have proper identity address set (public preferred).
  int rc = ble_hs_util_ensure_addr(0);
  if (rc != 0) {
    FATAL("error setting address; rc=%d", rc)
  }
  if (instance_) {
    BleCallbackScope scope;
    instance_->on_sync(scope);
  }
}

MODULE_IMPLEMENTATION(ble, MODULE_BLE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  BleEventSource* event_source = BleEventSource::instance();

  Mutex* mutex = OS::allocate_mutex(0, "BLE");
  if (!mutex) FAIL(MALLOC_FAILED);

  BleResourceGroup* group = _new BleResourceGroup(process, event_source, mutex);
  if (!group) {
    OS::dispose(mutex);
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create_adapter) {
  ARGS(BleResourceGroup, group)
  // Note that we don't take the BLE lock yet.
  // We are setting the lock in this function.

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int id = ble_pool.any();
  if (id == kInvalidBle) FAIL(ALREADY_IN_USE);

  // We can already set the callback, even though the adapter hasn't been created
  // yet.
  // The Adapter starts the NimBLE thread, so there won't be any callback before
  // the adapter was created, and its instance_ field has been set.
  ble_hs_cfg.sync_cb = BleAdapterResource::on_sync;

  auto adapter = _new BleAdapterResource(group, id);
  if (!adapter) {
    ble_pool.put(id);
    FAIL(MALLOC_FAILED);
  }

  group->register_resource(adapter);
  proxy->set_external_address(adapter);
  return proxy;
}

PRIMITIVE(create_central_manager) {
  ARGS(BleAdapterResource, adapter)

  Locker locker(adapter->group()->mutex());

  if (!adapter->is_active()) {
    // Either not yet synced, or already closed.
    FAIL(ERROR);
  }
  if (adapter->central_manager()) FAIL(ALREADY_IN_USE);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = adapter->group();

  auto central_manager = _new BleCentralManagerResource(group, adapter);
  if (!central_manager) FAIL(MALLOC_FAILED);

  group->register_resource(central_manager);
  proxy->set_external_address(central_manager);

  // On the ESP32 the central manager is immediately available.
  BleEventSource::instance()->on_event(central_manager, kBleStarted);

  return proxy;
}

PRIMITIVE(create_peripheral_manager) {
  ARGS(BleAdapterResource, adapter, bool, bonding, bool, secure_connections)

  Locker locker(adapter->group()->mutex());

  if (!adapter->is_active()) {
    // Either not yet synced, or already closed.
    FAIL(ERROR);
  }
  if (adapter->peripheral_manager()) FAIL(ALREADY_IN_USE);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = adapter->group();

  auto peripheral_manager = _new BlePeripheralManagerResource(group, adapter);
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

  ble_gatts_reset();

  // On the ESP32 the peripheral manager is immediately available.
  BleEventSource::instance()->on_event(peripheral_manager, kBleStarted);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(BleResourceGroup, group)
  // The close primitive, together with the init and create-adapter primitives, is the
  // only primitive that doesn't allocate a locker.
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(scan_start) {
  ARGS(BleCentralManagerResource, central_manager, bool, passive, int64, duration_us, int, interval, int, window, bool, limited)

  Locker locker(central_manager->group()->mutex());

  if (!central_manager->ensure_token()) FAIL(ALLOCATION_FAILED);

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

  disc_params.passive = passive ? 1 : 0;

  disc_params.itvl = interval;
  disc_params.window = window;
  // Don't filter.
  disc_params.filter_policy = 0;
  disc_params.limited = limited ? 1 : 0;

  err = ble_gap_disc(BLE_ADDR_PUBLIC, duration_ms, &disc_params,
                     BleCentralManagerResource::on_discovery, central_manager->token());

  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }

  return process->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BleCentralManagerResource, central_manager)

  Locker locker(central_manager->group()->mutex());

  DiscoveredPeripheral* next = central_manager->get_discovered_peripheral();
  if (!next) return process->null_object();

  Array* array = process->object_heap()->allocate_array(5, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  ByteArray* id = process->object_heap()->allocate_internal_byte_array(7);
  if (!id) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes id_bytes(id);
  id_bytes.address()[0] = next->addr().type;
  memcpy_reverse(id_bytes.address() + 1, next->addr().val, 6);
  array->at_put(0, id);

  array->at_put(1, Smi::from(next->rssi()));
  if (next->data_length() > 0) {
    ByteArray* data = process->object_heap()->allocate_internal_byte_array(next->data_length());
    if (!data) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes data_bytes(data);
    memcpy(data_bytes.address(), next->data(), next->data_length());
    array->at_put(2, data);
  }
  bool is_connectable = next->event_type() == BLE_HCI_ADV_RPT_EVTYPE_ADV_IND ||
                        next->event_type() == BLE_HCI_ADV_RPT_EVTYPE_DIR_IND;
  array->at_put(3, BOOL(is_connectable));
  bool is_scan_response = next->event_type() == BLE_HCI_ADV_RPT_EVTYPE_SCAN_RSP;
  array->at_put(4, BOOL(is_scan_response));

  central_manager->remove_discovered_peripheral();
  delete next;

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(BleResource, resource)

  Locker locker(resource->group()->mutex());

  if (BleCentralManagerResource::is_scanning()) {
    int err = ble_gap_disc_cancel();
    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
    // If ble_gap_disc_cancel returns without an error, the discovery has stopped and NimBLE will not provide an
    // event. So we fire the event manually.
    BleEventSource::instance()->on_event(resource, kBleCompleted);
  }

  return process->null_object();
}

PRIMITIVE(connect) {
  ARGS(BleCentralManagerResource, central_manager, Blob, address, bool, secure_connection)

  Locker locker(central_manager->group()->mutex());

  if (!central_manager->group()->token_resource_map.reserve_space()) FAIL(ALLOCATION_FAILED);

  uint8_t own_addr_type;

  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }

  ble_addr_t addr{};
  addr.type = address.address()[0];
  memcpy_reverse(addr.val, address.address() + 1, 6);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = central_manager->group();

  auto device = _new BleRemoteDeviceResource(group, central_manager, secure_connection);
  if (!device) FAIL(MALLOC_FAILED);
  // We reserved space at the top of the function, so this call must succeed.
  device->ensure_token();

  err = device->connect(own_addr_type, &addr);
  if (err != BLE_ERR_SUCCESS) {
    delete device;
    return nimble_stack_error(process, err);
  }

  proxy->set_external_address(device);
  group->register_resource(device);
  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(BleRemoteDeviceResource, device)

  Locker locker(device->group()->mutex());

  int err = device->disconnect();
  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }
  return process->null_object();
}

PRIMITIVE(release_resource) {
  ARGS(BleResource, resource)

  // We don't take the lock while calling unregister.
  resource->resource_group()->unregister_resource(resource);

  resource_proxy->clear_external_address();

  return process->null_object();
}

PRIMITIVE(discover_services) {
  ARGS(BleRemoteDeviceResource, device, Array, raw_service_uuids)

  Locker locker(device->group()->mutex());

  if (!device->ensure_token()) FAIL(ALLOCATION_FAILED);

  if (raw_service_uuids->length() == 0) {
    int err = ble_gattc_disc_all_svcs(
        device->handle(),
        BleRemoteDeviceResource::on_service_discovered,
        device->token());
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
        device->token());
    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
  } else FAIL(INVALID_ARGUMENT);

  return process->null_object();
}

PRIMITIVE(discover_services_result) {
  ARGS(BleRemoteDeviceResource, device)

  Locker locker(device->group()->mutex());

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

  Locker locker(service->group()->mutex());

  if (!service->ensure_token()) FAIL(ALLOCATION_FAILED);

  // NimBLE has a funny thing about descriptors (needed for subscriptions), where all characteristics
  // need to be discovered to discover descriptors. Therefore, we ignore the raw_characteristics_uuids
  // and always discover all, if they haven't been discovered yet.
  USE(raw_characteristics_uuids);
  if (!service->characteristics_discovered()) {
    int err = ble_gattc_disc_all_chrs(service->device()->handle(),
                                      service->start_handle(),
                                      service->end_handle(),
                                      BleServiceResource::on_characteristic_discovered,
                                      service->token());
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

  Locker locker(service->group()->mutex());

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

  Locker locker(characteristic->group()->mutex());

  // We always discover descriptors when discovering characteristics.
  BleEventSource::instance()->on_event(characteristic, kBleDescriptorsDiscovered);

  return process->null_object();
}

PRIMITIVE(discover_descriptors_result) {
  ARGS(BleCharacteristicResource, characteristic)

  Locker locker(characteristic->group()->mutex());

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
  ARGS(BleReadWriteElement, element)

  Locker locker(element->group()->mutex());

  if (!element->service()->device()) FAIL(INVALID_ARGUMENT);
  if (!element->ensure_token()) FAIL(ALLOCATION_FAILED);
  ble_gattc_read_long(element->service()->device()->handle(),
                      element->handle(),
                      0,
                      BleReadWriteElement::on_attribute_read,
                      element->token());

  return process->null_object();
}

PRIMITIVE(get_value) {
  ARGS(BleReadWriteElement, element)

  Locker locker(element->group()->mutex());

  const os_mbuf* mbuf = element->mbuf_received();
  if (!mbuf) return process->null_object();

  Object* ret_val = convert_mbuf_to_heap_object(process, mbuf);
  if (!ret_val) FAIL(ALLOCATION_FAILED);

  element->set_mbuf_received(null);
  return ret_val;
}

PRIMITIVE(write_value) {
  ARGS(BleReadWriteElement, element, Blob, value, bool, with_response, bool, allow_retry)

  Locker locker(element->group()->mutex());

  if (!element->service()->device()) FAIL(INVALID_ARGUMENT);

  if (with_response) {
    if (!element->ensure_token()) FAIL(ALLOCATION_FAILED);
  }

  int mtu;
  if (element->kind() == BleResource::CHARACTERISTIC) {
    auto characteristic = static_cast<BleCharacteristicResource*>(element);
    mtu = characteristic->get_mtu();
  } else {
    mtu = element->service()->device()->get_mtu();
  }
  if (value.length() + 3 > mtu) FAIL(OUT_OF_RANGE);

  os_mbuf* om = null;
  Object* error = blob_to_mbuf(process, value, &om);
  if (error) return error;

  int err;
  if (with_response) {
    err = ble_gattc_write_long(
        element->service()->device()->handle(),
        element->handle(),
        0,
        om,
        BleCharacteristicResource::on_write_response,
        element->token());
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
    if (allow_retry && err == BLE_HS_ENOMEM) {
      // Resource exhaustion.
      // This typically happens when writing too fast without flushing.
      // Use the quota-exceeded to signal that the write should be retried.
      FAIL(QUOTA_EXCEEDED);
    }
    return nimble_stack_error(process, err);
  }

  return Smi::from(with_response ? 1 : 0);
}

PRIMITIVE(handle) {
  ARGS(BleReadWriteElement, element)

  Locker locker(element->group()->mutex());

  return Smi::from(element->handle());
}

/* Enables or disables notifications/indications for the characteristic value
 * of $characteristic. If $characteristic allows both, notifications will be used.
*/
PRIMITIVE(set_characteristic_notify) {
  ARGS(BleCharacteristicResource, characteristic, bool, enable)

  Locker locker(characteristic->group()->mutex());

  if (!characteristic->ensure_token()) FAIL(ALLOCATION_FAILED);

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
        characteristic->token());

    if (err != BLE_ERR_SUCCESS) {
      return nimble_stack_error(process, err);
    }
  }

  return process->null_object();
}

PRIMITIVE(advertise_start) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(advertise_start_raw) {
  ARGS(BlePeripheralManagerResource, peripheral_manager, Blob, data, Object, scan_response, int, interval_us, int, connection_mode)

  Locker locker(peripheral_manager->group()->mutex());

  if (BlePeripheralManagerResource::is_advertising()) FAIL(ALREADY_EXISTS);
  if (!peripheral_manager->ensure_token()) FAIL(ALLOCATION_FAILED);

  int err = ble_gap_adv_set_data(data.address(), data.length());
  if (err != BLE_ERR_SUCCESS) {
    if (err == BLE_HS_EMSGSIZE) FAIL(OUT_OF_RANGE);
    return nimble_stack_error(process, err);
  }

  if (scan_response != process->null_object()) {
    Blob scan_response_data;
    if (!scan_response->byte_content(process->program(), &scan_response_data, STRINGS_OR_BYTE_ARRAYS)) {
      FAIL(WRONG_OBJECT_TYPE);
    }
    err = ble_gap_adv_rsp_set_data(scan_response_data.address(), scan_response_data.length());
    if (err != BLE_ERR_SUCCESS) {
      if (err == BLE_HS_EMSGSIZE) FAIL(OUT_OF_RANGE);
      return nimble_stack_error(process, err);
    }
  }

  peripheral_manager->advertising_params().conn_mode = connection_mode;

  // TODO(anders): Be able to tune this.
  peripheral_manager->advertising_params().disc_mode = BLE_GAP_DISC_MODE_GEN;

  int advertising_interval = interval_us / 625;
  peripheral_manager->advertising_params().itvl_min = advertising_interval;
  peripheral_manager->advertising_params().itvl_max = advertising_interval;

  err = do_start_advertising(peripheral_manager);
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

  Locker locker(peripheral_manager->group()->mutex());

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

  Locker locker(peripheral_manager->group()->mutex());

  ble_uuid_any_t ble_uuid = uuid_from_blob(uuid);

  auto existing = peripheral_manager->get_service(ble_uuid);
  if (existing) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  BleServiceResource* service_resource = peripheral_manager->get_or_create_service(null, ble_uuid, 0, 0);
  if (!service_resource) FAIL(MALLOC_FAILED);
  // On the peripheral side, setting the "returned" value isn't strictly necessary,
  // as all services are automatically returned. It is more consistent this way, though.
  service_resource->set_returned(true);

  proxy->set_external_address(service_resource);
  return proxy;
}

PRIMITIVE(add_characteristic) {
  ARGS(BleServiceResource, service_resource, Blob, raw_uuid, int, properties,
       int, permissions, Object, value)

  Locker locker(service_resource->group()->mutex());

  if (!service_resource->peripheral_manager()) FAIL(INVALID_ARGUMENT);
  if (service_resource->deployed()) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  ble_uuid_any_t ble_uuid = uuid_from_blob(raw_uuid);

  auto existing = service_resource->get_characteristic(ble_uuid);
  if (existing) FAIL(INVALID_ARGUMENT);

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

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  BleCharacteristicResource* characteristic = service_resource->get_or_create_characteristic(null, ble_uuid, flags, 0, 0);

  if (!characteristic) {
    if (om != null) os_mbuf_free(om);
    FAIL(MALLOC_FAILED);
  }

  if (om != null) {
    characteristic->set_mbuf_to_send(om);
  }
  // On the peripheral side, setting the "returned" value isn't strictly necessary,
  // as all characteristics are automatically returned. It is more consistent this way, though.
  characteristic->set_returned(true);

  proxy->set_external_address(characteristic);
  return proxy;
}

PRIMITIVE(add_descriptor) {
  ARGS(BleCharacteristicResource, characteristic, Blob, raw_uuid, int, properties, int, permissions, Object, value)

  Locker locker(characteristic->group()->mutex());

  if (!characteristic->service()->peripheral_manager()) FAIL(INVALID_ARGUMENT);
  if (characteristic->service()->deployed()) FAIL(INVALID_ARGUMENT);

  ble_uuid_any_t ble_uuid = uuid_from_blob(raw_uuid);

  auto existing = characteristic->get_descriptor(ble_uuid);
  if (existing) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  uint8 flags = 0;
  if (permissions & 0x01 || properties & BLE_GATT_CHR_F_READ) flags |= BLE_ATT_F_READ;
  if (permissions & 0x02 || properties & (BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP)) flags |= BLE_ATT_F_WRITE;
  if (permissions & 0x04) flags |= BLE_ATT_F_READ_ENC; // _ENC = Encrypted.
  if (permissions & 0x08) flags |= BLE_ATT_F_WRITE_ENC; // _ENC = Encrypted.

  BleDescriptorResource* descriptor =
      characteristic->get_or_create_descriptor(null, ble_uuid, 0, flags);
  if (!descriptor) {
    if (om != null) os_mbuf_free(om);
    FAIL(MALLOC_FAILED);
  }

  if (om != null) descriptor->set_mbuf_to_send(om);

  // On the peripheral side, setting the "returned" value isn't strictly necessary,
  // as all descriptors are automatically returned. It is more consistent this way, though.
  descriptor->set_returned(true);

  proxy->set_external_address(descriptor);
  return proxy;
}

PRIMITIVE(reserve_services) {
  ARGS(BlePeripheralManagerResource, peripheral_manager, int, count);

  auto adapter = BleAdapterResource::instance();
  if (adapter->started()) FAIL(ALREADY_IN_USE);
  if (count < 0) FAIL(INVALID_ARGUMENT);
  if (!adapter->reserve_services(count)) FAIL(MALLOC_FAILED);
  return process->null_object();
}

PRIMITIVE(deploy_service) {
  ARGS(BleServiceResource, service_resource, int, index)

  Locker locker(service_resource->group()->mutex());

  if (!service_resource->peripheral_manager()) FAIL(INVALID_ARGUMENT);
  if (service_resource->deployed()) FAIL(INVALID_ARGUMENT);

  auto adapter = BleAdapterResource::instance();
  if (index < 0 || index >= adapter->services_capacity()) FAIL(INVALID_ARGUMENT);

  int characteristic_count = 0;
  for (auto characteristic : service_resource->characteristics()) {
    characteristic_count++;

    if (!characteristic->ensure_token()) FAIL(MALLOC_FAILED);

    for (auto descriptor : characteristic->descriptors()) {
      if (!descriptor->ensure_token()) FAIL(MALLOC_FAILED);
    }
  }

  auto gatt_svr_chars = static_cast<ble_gatt_chr_def*>(calloc(characteristic_count + 1, sizeof(ble_gatt_chr_def)));
  if (!gatt_svr_chars) FAIL(MALLOC_FAILED);

  int characteristic_index = 0;
  for (auto characteristic : service_resource->characteristics()) {
    gatt_svr_chars[characteristic_index].uuid = characteristic->ptr_uuid();
    gatt_svr_chars[characteristic_index].access_cb = BleReadWriteElement::on_access;
    gatt_svr_chars[characteristic_index].arg = characteristic->token();
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
        BleServiceResource::dispose_gatt_svr_chars(gatt_svr_chars);
        FAIL(MALLOC_FAILED);
      }

      gatt_svr_chars[characteristic_index].descriptors = gatt_desc_defs;

      int descriptor_index = 0;
      for (auto descriptor : characteristic->descriptors()) {
        gatt_desc_defs[descriptor_index].uuid = descriptor->ptr_uuid();
        gatt_desc_defs[descriptor_index].att_flags = descriptor->properties();
        gatt_desc_defs[descriptor_index].access_cb = BleReadWriteElement::on_access;
        gatt_desc_defs[descriptor_index].arg = descriptor->token();
        descriptor_index++;
      }
    }
    characteristic_index++;
  }

  static_assert(BLE_GATT_SVC_TYPE_END == 0, "Unexpected BLE_GATT_SVC_TYPE_END value");

  struct ble_gatt_svc_def gatt_svc = {
    .type = BLE_GATT_SVC_TYPE_PRIMARY,
    .uuid = service_resource->ptr_uuid(),
    .includes = 0,
    .characteristics = gatt_svr_chars
  };

  adapter->store_nimble_service_definition(index, gatt_svc);

  // NimBLE does not do async service deployments, so
  // simulate success event.
  BleEventSource::instance()->on_event(service_resource, kBleServiceAddSucceeded);

  return process->null_object();
}

PRIMITIVE(start_gatt_server) {
  ARGS(BlePeripheralManagerResource, peripheral_manager)

  Locker locker(peripheral_manager->group()->mutex());

  auto adapter = BleAdapterResource::instance();

  if (adapter->started()) FAIL(ALREADY_IN_USE);
  int rc = adapter->start_peripheral();
  if (rc != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, rc);
  }

  return process->null_object();
}

PRIMITIVE(set_value) {
  ARGS(BleReadWriteElement, element, Object, value)

  Locker locker(element->group()->mutex());

  if (!element->service()->peripheral_manager()) FAIL(INVALID_ARGUMENT);

  os_mbuf* om = null;
  Object* error = object_to_mbuf(process, value, &om);
  if (error) return error;

  element->set_mbuf_to_send(om);

  return process->null_object();
}

PRIMITIVE(get_subscribed_clients) {
  ARGS(BleCharacteristicResource, characteristic)

  Locker locker(characteristic->group()->mutex());

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

  Locker locker(characteristic->group()->mutex());

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

  if (err != BLE_ERR_SUCCESS && err != BLE_HS_ENOTCONN) {
    // The 'om' buffer is always consumed by the call to
    // ble_gattc_notify_custom() or ble_gattc_indicate_custom()
    // regardless of the outcome.
    return nimble_host_stack_error(process, err);
  }

  return process->null_object();
}

PRIMITIVE(get_att_mtu) {
  ARGS(BleResource, ble_resource)

  Locker locker(ble_resource->group()->mutex());

  uint16 mtu = BLE_ATT_MTU_DFLT;
  switch (ble_resource->kind()) {
    case BleResource::REMOTE_DEVICE: {
      auto device = static_cast<BleRemoteDeviceResource*>(ble_resource);
      mtu = ble_att_mtu(device->handle());
      break;
    }
    case BleResource::CHARACTERISTIC: {
      auto characteristic = static_cast<BleCharacteristicResource*>(ble_resource);
      mtu = characteristic->get_mtu();
      break;
    }
    default: {
      FAIL(INVALID_ARGUMENT);
    }
  }
  return Smi::from(mtu);
}

PRIMITIVE(set_preferred_mtu) {
  ARGS(BleAdapterResource, adapter, int, mtu)

  Locker locker(adapter->group()->mutex());

  if (mtu > BLE_ATT_MTU_MAX) FAIL(INVALID_ARGUMENT);

  int result = ble_att_set_preferred_mtu(mtu);

  if (result) {
    FAIL(INVALID_ARGUMENT);
  } else {
    return process->null_object();
  }
}

PRIMITIVE(get_error) {
  ARGS(BleCallbackResource, err_resource, bool, is_oom)

  Locker locker(err_resource->group()->mutex());

  if (is_oom) {
    if (!err_resource->has_malloc_error()) FAIL(ERROR);
    FAIL(MALLOC_FAILED);
  }
  if (err_resource->error() == 0) FAIL(ERROR);
  return nimble_error_code_to_string(process, err_resource->error(), true);
}

PRIMITIVE(clear_error) {
  ARGS(BleCallbackResource, err_resource, bool, is_oom)

  Locker locker(err_resource->group()->mutex());

  if (is_oom) {
    if (!err_resource->has_malloc_error()) FAIL(ERROR);
    err_resource->set_malloc_error(false);
  } else {
    if (err_resource->error() == 0) FAIL(ERROR);
    err_resource->set_error(0);
  }
  return process->null_object();
}

PRIMITIVE(toit_callback_init) {
  ARGS(BleCharacteristicResource, characteristic, int, timeout_ms, bool, for_read)

  Locker locker(characteristic->group()->mutex());

  if (timeout_ms < 0 || timeout_ms > 10000) FAIL(INVALID_ARGUMENT);
  if (characteristic->toit_callback_is_setup(for_read)) FAIL(ALREADY_IN_USE);
  if (!characteristic->toit_callback_init(timeout_ms, for_read)) FAIL(MALLOC_FAILED);
  return process->null_object();
}

PRIMITIVE(toit_callback_deinit) {
  ARGS(BleCharacteristicResource, characteristic, bool, for_read)

  Locker locker(characteristic->group()->mutex());

  if (!characteristic->toit_callback_is_setup(for_read)) {
    return process->null_object();
  }
  characteristic->toit_callback_deinit(for_read);
  return process->null_object();
}

PRIMITIVE(toit_callback_reply) {
  ARGS(BleCharacteristicResource, characteristic, Object, value, bool, for_read)

  Locker locker(characteristic->group()->mutex());

  // We might throw if the callback is too late.
  if (!characteristic->toit_callback_needs_value(for_read)) FAIL(INVALID_STATE);

  if (!for_read && value != process->null_object()) FAIL(INVALID_ARGUMENT);

  os_mbuf* mbuf = null;
  Object* error = object_to_mbuf(process, value, &mbuf);
  if (error) return error;

  characteristic->toit_callback_handle_reply(mbuf, for_read);

  return process->null_object();
}

PRIMITIVE(get_bonded_peers) {
  ARGS(BleCentralManagerResource, central_manager);

  Locker locker(central_manager->group()->mutex());

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

PRIMITIVE(set_gap_device_name) {
  ARGS(BleAdapterResource, adapter, cstring, name)

  Locker locker(adapter->group()->mutex());

  int err = ble_svc_gap_device_name_set(name);
  if (err != BLE_ERR_SUCCESS) {
    return nimble_stack_error(process, err);
  }

  return process->null_object();
}

} // namespace toit

#endif // defined(TOIT_ESP32) && defined(CONFIG_BT_ENABLED)
