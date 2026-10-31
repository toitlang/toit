// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#if defined(TOIT_ZEPHYR) && CONFIG_BT
#include "../event_sources/ble.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "ble_zephyr_data.h"
#include "ble_zephyr_lock.h"
#include "ble_zephyr_server.h"
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#if CONFIG_BT_SETTINGS
#include <zephyr/settings/settings.h>
#endif
#if CONFIG_SOC_NRF5340_CPUAPP
#include <hal/nrf_reset.h>
#endif

namespace toit {
// The Bluetooth RX thread is not a Toit Thread: it must not acquire OS::Mutex
// or dispatch directly into the scheduler. Copy reports under this kernel
// mutex and use ZephyrResource::notify to wake the normal event worker.
static bool adapter_claimed = false;
static bool controller_broken = false;
class BleCentralManagerResource;
static BleCentralManagerResource* current_scan = null;
static bool connection_pending();  // Caller holds callback_mutex.
static void release_retired_services();  // After successful bt_disable.
#if CONFIG_TOIT_BLE_SECURITY
static int register_security_callbacks();
#endif

class BleCallbackResource : public BleResource {
 public:
  TAGS(BleCallbackResource);
  BleCallbackResource(ResourceGroup* group, Kind kind) : BleResource(group, kind) {}
  // Both event-source and callback mutexes must be held when clearing flags.
  void clear_events(uint32_t mask) {
    uint32_t keep = take_pending() & ~mask;
    set_state(state() & ~mask);
    if (keep) notify(keep);
  }
  int error = 0;  // Protected by callback_mutex.
};

// These two concrete tags are adjacent; other platforms use their existing
// service/characteristic classes instead of this shared Zephyr attribute type.
static constexpr int BleGattResourceMinTag = BleRemoteDeviceResourceTag;
static constexpr int BleGattResourceMaxTag = BleGattAttributeResourceTag;
class BleGattResource;
struct BleGattDiscovery {
  bt_gatt_discover_params params = {};
  bt_uuid_128 filter_uuid = {};
  bt_uuid_16 filter_uuid16 = {};
  BleZephyrUuid filter;
  BleZephyrAttributes attributes;
  BleGattResource* owner = null;
  unsigned references = 1;  // Owner; add a second reference while Zephyr uses params.
  bool active = false;
  int error = 0;
  uint32_t completed_event = 0;
  BleResource::Kind result_kind = BleResource::SERVICE;
  void release() { if (--references == 0) delete this; }  // callback_mutex held.
  void finish(int result);
  static uint8_t received(bt_conn*, const bt_gatt_attr*, bt_gatt_discover_params*);
};

class BleGattResource : public BleCallbackResource {
 public:
  TAGS(BleGattResource);
  BleGattResource(ResourceGroup* group, Kind kind, bt_conn* connection = null)
      : BleCallbackResource(group, kind), connection_(connection ? bt_conn_ref(connection) : null) {
    next_gatt_ = first_gatt_;
    first_gatt_ = this;
  }
  ~BleGattResource() override {
    {
      CallbackLock lock;
      auto link = &first_gatt_;
      while (*link != this) link = &(*link)->next_gatt_;
      *link = next_gatt_;
    }
    discard_discovery();
    if (connection_) bt_conn_unref(connection_);
  }
  void discard_discovery() {
    BleGattDiscovery* operation;
    bool active;
    {
      CallbackLock lock;
      operation = discovery;
      if (!operation) return;
      discovery = null;
      operation->owner = null;
      active = operation->active;
    }
    // Cancellation can call received synchronously. Retain the owner's
    // reference across the call, and never hold callback_mutex here.
    if (active) bt_gatt_cancel(connection_, &operation->params);
    CallbackLock lock;
    operation->release();
  }
  int discover(uint8_t type, uint16_t start, uint16_t end, const BleZephyrUuid& filter) {
    auto operation = _new BleGattDiscovery;
    if (!operation) return -ENOMEM;
    operation->params.func = BleGattDiscovery::received;
    operation->params.type = type;
    operation->params.start_handle = start;
    operation->params.end_handle = end;
    operation->filter = filter;
    if (type == BT_GATT_DISCOVER_PRIMARY) {
      operation->completed_event = kBleServicesDiscovered;
      operation->result_kind = SERVICE;
      if (filter.length) {
        // Use the compact form for Bluetooth-assigned services. Some peers
        // compare Find By Type Value requests with the declaration's wire
        // bytes, so an equivalent expanded UUID does not find a 16-bit UUID.
        if (filter.as16(&operation->filter_uuid16.val)) {
          operation->filter_uuid16.uuid.type = BT_UUID_TYPE_16;
          operation->params.uuid = &operation->filter_uuid16.uuid;
        } else {
          uint8_t canonical[16];
          filter.canonical(canonical);
          operation->filter_uuid.uuid.type = BT_UUID_TYPE_128;
          for (int i = 0; i < 16; ++i) operation->filter_uuid.val[i] = canonical[15 - i];
          operation->params.uuid = &operation->filter_uuid.uuid;
        }
      }
    } else if (type == BT_GATT_DISCOVER_CHARACTERISTIC) {
      operation->completed_event = kBleCharacteristicsDiscovered;
      operation->result_kind = CHARACTERISTIC;
    } else {
      operation->completed_event = kBleDescriptorsDiscovered;
      operation->result_kind = DESCRIPTOR;
    }
    {
      Locker event_lock(resource_group()->event_source()->mutex());
      CallbackLock lock;
      bt_conn_info info;
      int result = 0;
      if (controller_broken) result = -EIO;
      else if (!connection_ || bt_conn_get_info(connection_, &info) || info.state != BT_CONN_STATE_CONNECTED) result = -ENOTCONN;
      else if (operation_busy()) result = -EALREADY;
      if (result) { delete operation; return result; }
      if (discovery) { discovery->owner = null; discovery->release(); }
      discovery = operation;
      operation->owner = this;
      operation->active = true;
      ++operation->references;
      error = 0;
      clear_events(kBleServicesDiscovered | kBleCharacteristicsDiscovered |
          kBleDescriptorsDiscovered | kBleDiscoverOperationFailed);
    }
    int result = start <= end ? bt_gatt_discover(connection_, &operation->params) : 0;
    if (result || start > end) {
      CallbackLock lock;
      operation->finish(result);
    }
    return result;
  }
  bt_conn* connection() const { return connection_; }
  virtual bool operation_busy() const { return discovery && discovery->active; }
  static void disconnected(bt_conn* connection) {
    // Called with callback_mutex held; notify every attribute on this link.
    for (auto p = first_gatt_; p; p = p->next_gatt_) {
      if (p->connection_ != connection) continue;
      p->error = -ENOTCONN;
      p->notify(kBleDisconnected);
    }
  }
  BleGattDiscovery* discovery = null;
 protected:
  bt_conn* connection_ = null;
 private:
  BleGattResource* next_gatt_;
  static BleGattResource* first_gatt_;
};
BleGattResource* BleGattResource::first_gatt_ = null;

static bool copy_uuid(BleZephyrUuid* result, const bt_uuid* uuid) {
  if (!uuid) return false;
  if (uuid->type == BT_UUID_TYPE_16) {
    uint16_t value = BT_UUID_16(uuid)->val;
    uint8_t bytes[] = {static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)};
    return result->set(bytes, 2);
  }
  if (uuid->type == BT_UUID_TYPE_32) {
    uint32_t value = BT_UUID_32(uuid)->val;
    uint8_t bytes[4];
    for (int i = 0; i < 4; ++i) bytes[i] = value >> ((3 - i) * 8);
    return result->set(bytes, 4);
  }
  if (uuid->type == BT_UUID_TYPE_128) {
    uint8_t bytes[16];
    for (int i = 0; i < 16; ++i) bytes[i] = BT_UUID_128(uuid)->val[15 - i];
    return result->set(bytes, 16);
  }
  return false;
}

void BleGattDiscovery::finish(int result) {
  if (!active) return;
  active = false;
  error = result;
  if (owner) {
    owner->error = result;
    owner->notify(result ? kBleDiscoverOperationFailed : completed_event);
  }
  release();  // Zephyr has stopped using params; the owner may already be gone.
}

uint8_t BleGattDiscovery::received(bt_conn* connection, const bt_gatt_attr* attr,
                                  bt_gatt_discover_params* params) {
  auto self = CONTAINER_OF(params, BleGattDiscovery, params);
  CallbackLock lock;
  if (!self->owner) {
    self->finish(-ECANCELED);
    return BT_GATT_ITER_STOP;
  }
  if (!attr) {
    bt_conn_info info;
    bool connected = !bt_conn_get_info(connection, &info) && info.state == BT_CONN_STATE_CONNECTED;
    self->finish(connected ? 0 : -ENOTCONN);
    return BT_GATT_ITER_STOP;
  }
  BleZephyrAttribute record;
  record.start = attr->handle;
  record.end = self->params.end_handle;
  const bt_uuid* uuid = attr->uuid;
  if (self->result_kind == BleResource::SERVICE) {
    if (!attr->user_data) { self->finish(-EPROTO); return BT_GATT_ITER_STOP; }
    auto value = static_cast<const bt_gatt_service_val*>(attr->user_data);
    uuid = value->uuid;
    record.end = value->end_handle;
  } else if (self->result_kind == BleResource::CHARACTERISTIC) {
    if (!attr->user_data) { self->finish(-EPROTO); return BT_GATT_ITER_STOP; }
    auto value = static_cast<const bt_gatt_chrc*>(attr->user_data);
    uuid = value->uuid;
    record.value = value->value_handle;
    record.properties = value->properties;
  } else {
    record.end = record.start;
    record.value = record.start;
  }
  if (!copy_uuid(&record.uuid, uuid) || record.end > params->end_handle) {
    self->finish(-EPROTO);
    return BT_GATT_ITER_STOP;
  }
  bool full = self->attributes.count == BleZephyrAttributes::CAPACITY;
  if (!self->attributes.push(record, self->result_kind == BleResource::CHARACTERISTIC)) {
    self->finish(full ? -ENOBUFS : -EPROTO);
    return BT_GATT_ITER_STOP;
  }
  return BT_GATT_ITER_CONTINUE;
}

class BleGattAttributeResource;
struct BleSubscriptionChange;
struct BleSubscription {
  bt_gatt_subscribe_params params = {};
  bt_conn* connection;
  BleGattAttributeResource* owner;
  BleZephyrNotifications notifications;
  BleSubscriptionChange* pending = null;
  BleSubscription* next;
  unsigned references = 1;  // Owner, local registration, and each CCC request.
  int notification_error = 0;
  bool registered = false, enabled = false, cleanup = false;
  BleSubscription(BleGattAttributeResource*, bt_conn*);
  ~BleSubscription();
  void retain() { ++references; }
  void release() { if (--references == 0) delete this; }
  static uint8_t received(bt_conn*, bt_gatt_subscribe_params*, const void*, uint16_t);
};
struct BleSubscriptionChange {
  bt_gatt_write_params params = {};
  uint8_t value[2] = {};
  BleSubscription* route;
  unsigned references = 2;  // Starting call and Zephyr callback.
  bool active = true, enable, report;
  BleSubscriptionChange(BleSubscription* route, bool enable, bool report)
      : route(route), enable(enable), report(report) { route->retain(); }
  ~BleSubscriptionChange() { route->release(); }
  void retain() { ++references; }
  void release() { if (--references == 0) delete this; }
  void finish(int);
  static void written(bt_conn*, uint8_t, bt_gatt_write_params*);
};
static void stop_subscription_cleanup();

struct BleGattValueOperation {
  bt_gatt_read_params read_params = {};
  bt_gatt_write_params write_params = {};
  BleZephyrValue value;
  BleGattAttributeResource* owner = null;
  unsigned references = 1;
  bool active = false, writing = false;
  int error = 0;  // Positive ATT status or negative errno.
  void release() { if (--references == 0) delete this; }  // callback_mutex held.
  void finish(int result);
  static uint8_t received(bt_conn*, uint8_t, bt_gatt_read_params*, const void*, uint16_t);
  static void written(bt_conn*, uint8_t, bt_gatt_write_params*);
};

class BleGattAttributeResource : public BleGattResource {
 public:
  TAG(BleGattAttributeResource);
  BleGattAttributeResource(BleGattResource* parent, Kind kind, const BleZephyrAttribute& value)
      : BleGattResource(parent->resource_group(), kind, parent->connection()), attribute(value) {}
  ~BleGattAttributeResource() override {
    discard_value(false);
    discard_value(true);
    cancel_subscription(true);
  }
  bool operation_busy() const override {
    return BleGattResource::operation_busy() || (read && read->active) || (write && write->active) ||
        (subscription && subscription->pending);
  }
  void discard_value(bool writing) {
    BleGattValueOperation* operation;
    bool active;
    {
      CallbackLock lock;
      auto& slot = writing ? write : read;
      operation = slot;
      if (!operation) return;
      slot = null;
      operation->owner = null;
      active = operation->active;
    }
    if (active) bt_gatt_cancel(connection_, writing
        ? static_cast<void*>(&operation->write_params)
        : static_cast<void*>(&operation->read_params));
    CallbackLock lock;
    operation->release();
  }
  int start_value(bool writing, const uint8_t* data = null, size_t length = 0) {
    auto operation = _new BleGattValueOperation;
    if (!operation) return -ENOMEM;
    operation->writing = writing;
    if (writing) {
      if (!operation->value.append(data, length)) { delete operation; return -EMSGSIZE; }
      operation->write_params.func = BleGattValueOperation::written;
      operation->write_params.handle = attribute.value;
      operation->write_params.data = operation->value.bytes;
      operation->write_params.length = length;
    } else {
      operation->read_params.func = BleGattValueOperation::received;
      operation->read_params.handle_count = 1;
      operation->read_params.single.handle = attribute.value;
    }
    {
      Locker event_lock(resource_group()->event_source()->mutex());
      CallbackLock lock;
      bt_conn_info info;
      int result = 0;
      if (controller_broken) result = -EIO;
      else if (bt_conn_get_info(connection_, &info) || info.state != BT_CONN_STATE_CONNECTED) result = -ENOTCONN;
      else if (operation_busy()) result = -EALREADY;
      if (result) { delete operation; return result; }
      auto& slot = writing ? write : read;
      if (slot) { slot->owner = null; slot->release(); }
      slot = operation;
      operation->owner = this;
      operation->active = true;
      ++operation->references;
      error = 0;
      clear_events(writing ? kBleValueWriteSucceeded | kBleValueWriteFailed
                           : kBleValueDataReady | kBleValueDataReadFailed);
    }
    int result = writing ? bt_gatt_write(connection_, &operation->write_params)
                         : bt_gatt_read(connection_, &operation->read_params);
    if (result) {
      // No request was queued. Do not emit an asynchronous failure event that
      // could race with the shared library's retry after QUOTA_EXCEEDED.
      CallbackLock lock;
      (writing ? write : read) = null;
      operation->owner = null;
      operation->finish(result);
      operation->release();
    }
    return result;
  }
  int configure_subscription(bool enable);
  void cancel_subscription(bool detach = false);
  BleSubscription* subscription = null;
  uint16_t ccc_handle = 0;
  BleZephyrAttribute attribute;
  BleGattValueOperation* read = null;
  BleGattValueOperation* write = null;
};

void BleGattValueOperation::finish(int result) {
  if (!active) return;
  active = false;
  error = result;
  if (owner) {
    owner->error = result;
    owner->notify(writing
        ? (result ? kBleValueWriteFailed : kBleValueWriteSucceeded)
        : (result ? kBleValueDataReadFailed : kBleValueDataReady));
  }
  release();
}
uint8_t BleGattValueOperation::received(bt_conn* connection, uint8_t status,
    bt_gatt_read_params* params, const void* data, uint16_t length) {
  USE(connection);
  auto self = CONTAINER_OF(params, BleGattValueOperation, read_params);
  CallbackLock lock;
  if (!self->owner) { self->finish(-ECANCELED); return BT_GATT_ITER_STOP; }
  if (status || !data) { self->finish(status); return BT_GATT_ITER_STOP; }
  if (!self->value.append(data, length)) {
    self->finish(-EMSGSIZE);
    return BT_GATT_ITER_STOP;
  }
  // Zephyr continues with Read Blob when this fragment fills ATT_MTU - 1.
  return BT_GATT_ITER_CONTINUE;
}
void BleGattValueOperation::written(bt_conn* connection, uint8_t status, bt_gatt_write_params* params) {
  USE(connection);
  auto self = CONTAINER_OF(params, BleGattValueOperation, write_params);
  CallbackLock lock;
  self->finish(self->owner ? status : -ECANCELED);
}

// Keep one local notification route per connection/value handle until the
// connection ends. CCC writes have separate parameter ownership. This avoids
// treating a NULL notification callback as the last access to parameters that
// Zephyr can still use for a CCC response callback. Closed routes are reusable
// on the same connection, and the bounded table cannot grow without limit.
static BleSubscription* subscriptions = null;
static unsigned subscription_count = 0;
static constexpr unsigned MAX_SUBSCRIPTIONS = 16;
static bool subscription_cleanup_running = false;
static void subscription_cleanup(struct k_work*);
static K_WORK_DELAYABLE_DEFINE(subscription_cleanup_work, subscription_cleanup);
static void kick_subscription_cleanup() {
  if (subscription_cleanup_running) k_work_reschedule(&subscription_cleanup_work, K_NO_WAIT);
}
BleSubscription::BleSubscription(BleGattAttributeResource* owner, bt_conn* connection)
    : connection(bt_conn_ref(connection)), owner(owner), next(subscriptions) {
  subscriptions = this;
  ++subscription_count;
}
BleSubscription::~BleSubscription() {
  auto link = &subscriptions;
  while (*link != this) link = &(*link)->next;
  *link = next;
  --subscription_count;
  bt_conn_unref(connection);
}
void BleSubscriptionChange::finish(int result) {
  if (!active) return;
  active = false;
  route->pending = null;
  if (report) {
    route->enabled = result == 0 && enable;
    if (route->owner) {
      route->owner->error = result;
      route->owner->notify(result ? kBleSubscriptionOperationFailed : kBleSubscriptionOperationSucceeded);
    }
  }
  if (route->cleanup) kick_subscription_cleanup();
  release();
}
void BleSubscriptionChange::written(bt_conn* connection, uint8_t status, bt_gatt_write_params* params) {
  USE(connection);
  auto self = CONTAINER_OF(params, BleSubscriptionChange, params);
  CallbackLock lock;
  self->finish(status);
}
static int change_subscription(BleSubscription* route, bool enable, bool report) {
  BleSubscriptionChange* operation;
  {
    CallbackLock lock;
    if (!route->registered) return -ENOTCONN;
    if (route->pending) return -EALREADY;
    operation = _new BleSubscriptionChange(route, enable, report);
    if (!operation) {
      route->enabled = false;
      return -ENOMEM;
    }
    route->pending = operation;
    operation->value[0] = enable ? route->params.value : 0;
    operation->params.func = BleSubscriptionChange::written;
    operation->params.handle = route->params.ccc_handle;
    operation->params.data = operation->value;
    operation->params.length = 2;
  }
  int result = bt_gatt_write(route->connection, &operation->params);
  CallbackLock lock;
  if (result) {
    operation->report = false;  // The initiating call reports the error directly.
    route->enabled = false;
    operation->finish(result);
  }
  operation->release();
  return result;
}
uint8_t BleSubscription::received(bt_conn* connection, bt_gatt_subscribe_params* params,
                                 const void* data, uint16_t length) {
  USE(connection);
  auto self = CONTAINER_OF(params, BleSubscription, params);
  CallbackLock lock;
  if (!data) {
    self->registered = false;
    self->enabled = false;
    self->cleanup = false;
    self->notifications.clear();
    self->notification_error = -ENOTCONN;
    if (self->owner) self->owner->notify(kBleNotificationReady | kBleDisconnected);
    self->release();  // Local registration. No CCC callback uses these params.
    return BT_GATT_ITER_CONTINUE;
  }
  if (!self->owner || !self->enabled || self->notification_error) return BT_GATT_ITER_CONTINUE;
  if (!self->notifications.push(data, length)) {
    self->notifications.clear();
    self->notification_error = length > BleZephyrValue::CAPACITY ? -EMSGSIZE : -ENOBUFS;
    self->enabled = false;
    self->cleanup = true;
    kick_subscription_cleanup();
  }
  self->owner->notify(kBleNotificationReady);
  // Never return STOP: Zephyr would start its own unsubscribe/CCC procedure
  // using the local-routing params, defeating their separate lifetime.
  return BT_GATT_ITER_CONTINUE;
}
static void subscription_cleanup(struct k_work* work) {
  USE(work);
  for (;;) {
    BleSubscription* route = null;
    {
      CallbackLock lock;
      if (!subscription_cleanup_running) return;
      for (auto p = subscriptions; p; p = p->next) {
        if (p->registered && p->cleanup && !p->pending) { route = p; break; }
      }
      if (!route) return;
      route->cleanup = false;
      route->retain();
    }
    // Zephyr makes ATT request/PDU allocation nonblocking in the system work
    // queue. Retry memory pressure without blocking Bluetooth's TX processing.
    int result = change_subscription(route, false, false);
    CallbackLock lock;
    if ((result == -ENOMEM || result == -EALREADY) && route->registered) {
      route->cleanup = true;
      if (subscription_cleanup_running) k_work_reschedule(&subscription_cleanup_work, K_MSEC(10));
      route->release();
      return;
    }
    route->release();
  }
}
static void stop_subscription_cleanup() {
  {
    CallbackLock lock;
    subscription_cleanup_running = false;
  }
  struct k_work_sync sync;
  k_work_cancel_delayable_sync(&subscription_cleanup_work, &sync);
}
int BleGattAttributeResource::configure_subscription(bool enable) {
  BleSubscription* route;
  {
    Locker event_lock(resource_group()->event_source()->mutex());
    CallbackLock lock;
    if (controller_broken) return -EIO;
    if (subscription && (subscription->cleanup || (subscription->pending && !subscription->pending->report))) return -EBUSY;
    if (operation_busy()) return -EALREADY;
    clear_events(kBleSubscriptionOperationSucceeded | kBleSubscriptionOperationFailed);
    error = 0;
    route = subscription;
    if (!enable && (!route || !route->registered)) {
      notify(kBleSubscriptionOperationSucceeded | kBleNotificationReady);
      return 0;
    }
    if (enable && route && route->enabled && !route->notification_error) {
      notify(kBleSubscriptionOperationSucceeded);
      return 0;
    }
    if (!ccc_handle) return -ENOENT;
    if (!route) {
      for (auto p = subscriptions; p; p = p->next) {
        if (p->connection == connection_ && p->params.value_handle == attribute.value) {
          if (p->owner) return -EALREADY;
          if (p->pending || p->cleanup) return -EBUSY;
          route = p;
          break;
        }
      }
      if (route) {
        route->retain();
        route->owner = this;
      } else {
        if (subscription_count == MAX_SUBSCRIPTIONS) return -ENOSPC;
        route = _new BleSubscription(this, connection_);
        if (!route) return -ENOMEM;
        route->params.notify = BleSubscription::received;
        route->params.value_handle = attribute.value;
        route->params.ccc_handle = ccc_handle;
        route->params.value = attribute.properties & BT_GATT_CHRC_NOTIFY ? BT_GATT_CCC_NOTIFY : BT_GATT_CCC_INDICATE;
        atomic_set_bit(route->params.flags, BT_GATT_SUBSCRIBE_FLAG_VOLATILE);
        atomic_set_bit(route->params.flags, BT_GATT_SUBSCRIBE_FLAG_NO_RESUB);
        // This port is single-core. Protect the nonblocking local registration
        // and connection-state check from the cooperative Bluetooth RX thread.
        // resubscribe installs local routing only; our separate write configures
        // the peer's CCC and owns its response lifetime.
        BUILD_ASSERT(!IS_ENABLED(CONFIG_SMP), "BLE local routing requires single-core Zephyr");
        k_sched_lock();
        bt_conn_info info;
        int result = bt_conn_get_info(connection_, &info);
        if (!result && info.state != BT_CONN_STATE_CONNECTED) result = -ENOTCONN;
        if (!result) result = bt_gatt_resubscribe(BT_ID_DEFAULT, bt_conn_get_dst(connection_), &route->params);
        if (!result) { route->registered = true; route->retain(); }
        k_sched_unlock();
        if (result) { route->owner = null; route->release(); return result; }
      }
      subscription = route;
    }
    route->notifications.clear();
    route->notification_error = 0;
    route->enabled = enable;
    subscription_cleanup_running = true;
    clear_events(kBleNotificationReady);
    if (!enable) notify(kBleNotificationReady);  // Wake a waiting receiver.
  }
  return change_subscription(route, enable, true);
}
void BleGattAttributeResource::cancel_subscription(bool detach) {
  BleSubscription* route;
  BleSubscriptionChange* pending;
  {
    CallbackLock lock;
    route = subscription;
    if (!route) return;
    route->retain();
    route->enabled = false;
    route->notifications.clear();
    route->notification_error = -ECANCELED;
    route->cleanup = route->registered;
    pending = route->pending;
    if (pending) { pending->report = false; pending->retain(); }
    if (detach) {
      subscription = null;
      route->owner = null;
      route->release();
    } else {
      notify(kBleNotificationReady);
    }
  }
  if (pending) bt_gatt_cancel(route->connection, &pending->params);
  CallbackLock lock;
  if (pending) pending->release();
  kick_subscription_cleanup();
  route->release();
}

class BleAdapterResource : public BleCallbackResource, public Thread {
 public:
  TAG(BleAdapterResource);
  explicit BleAdapterResource(ResourceGroup* group)
      : BleCallbackResource(group, ADAPTER), Thread("BLE initialization") {}
  ~BleAdapterResource() override {
    ASSERT(children == 0);
    if (worker_started_) join();
    stop_subscription_cleanup();
    bool force_off = !ready;
    if (enabled_) {
      // No event-source or callback lock is held across a synchronous HCI call.
      int result = bt_disable();
      if (result) {
        printf("[toit] Bluetooth disable failed: %d; reboot required\n", result);
        CallbackLock lock;
        controller_broken = true;
        force_off = true;
      } else {
        release_retired_services();
        force_off = false;
      }
    }
#if CONFIG_SOC_NRF5340_CPUAPP
    // Normal bt_disable uses Zephyr's nrf53_support.c transport hook. Failure
    // may skip that hook. Force the radio CPU off and prohibit reuse until
    // reboot; the failed host's on/off accounting cannot be safely retried.
    if (force_off) nrf_reset_network_force_off(NRF_RESET, true);
#else
    USE(force_off);
#endif
    CallbackLock lock;
    adapter_claimed = false;
  }
  bool initialize() { worker_started_ = spawn(); return worker_started_; }
  bool ready = false;
  int children = 0;
  bool central = false, peripheral = false;
 private:
  void entry() override {
    int result = 0;
#if CONFIG_TOIT_BLE_SECURITY
    result = register_security_callbacks();
#endif
    if (!result) result = bt_enable(NULL);
    enabled_ = result == 0;
#if CONFIG_BT_SETTINGS
    // Zephyr defers identity setup until its settings handler commits. Do not
    // publish a usable adapter before that finishes, including after reopen.
    if (enabled_) result = settings_load_subtree("bt");
#endif
    CallbackLock lock;
    error = result;
    ready = result == 0;
    // Zephyr cannot reliably retry a partially opened HCI transport. Do not
    // let a new adapter reuse it until a hardware restart has cleared it.
    if (result) controller_broken = true;
    notify(result ? kBleStartFailed : kBleStarted);
  }
  bool worker_started_ = false;
  bool enabled_ = false;  // The destructor joins before reading this flag.
};

class BleCentralManagerResource : public BleCallbackResource, public Thread {
 public:
  TAG(BleCentralManagerResource);
  BleCentralManagerResource(ResourceGroup* group, BleAdapterResource* adapter)
      : BleCallbackResource(group, CENTRAL_MANAGER), Thread("BLE scan"), adapter_(adapter) {
    k_sem_init(&start_, 0, 1);
    k_sem_init(&stop_, 0, 1);
    k_sem_init(&done_, 0, 1);
    adapter_->central = true;
    ++adapter_->children;
  }
  ~BleCentralManagerResource() override {
    ASSERT(devices == 0);
    stop();
    {
      CallbackLock lock;
      shutdown_ = true;
    }
    if (worker_started_) { k_sem_give(&start_); join(); }
    CallbackLock lock;
    adapter_->central = false;
    --adapter_->children;
  }
  bool initialize() { worker_started_ = spawn(); return worker_started_; }
  int start(const bt_le_scan_param& parameters, int64 duration, bool limited) {
    Locker event_lock(resource_group()->event_source()->mutex());
    CallbackLock lock;
    if (active_) return -EALREADY;
    if (connection_pending()) return -EBUSY;
    if (controller_broken) return -EIO;
    k_sem_reset(&stop_);
    k_sem_reset(&done_);
    reports.clear();
    take_pending();
    set_state(0);
    error = 0;
    parameters_ = parameters;
    duration_ = duration;
    limited_ = limited;
    active_ = true;
    k_sem_give(&start_);
    return 0;
  }
  void stop() {
    bool active;
    {
      CallbackLock lock;
      active = active_;
      if (active) k_sem_give(&stop_);
    }
    if (active) k_sem_take(&done_, K_FOREVER);
  }
  BleZephyrReports reports;
  bool scanning() const { return active_; }  // Caller holds callback_mutex.
  int devices = 0;
 private:
  static void received(const bt_addr_le_t* address, int8_t rssi, uint8_t type,
                       struct net_buf_simple* data) {
    CallbackLock lock;
    auto self = current_scan;
    if (self == null || data->len > 31) return;
    if (self->limited_ && !ble_zephyr_limited_ad(data->data, data->len)) return;
    BleZephyrReport report = {};
    report.address[0] = address->type;
    for (int i = 0; i < 6; ++i) report.address[i + 1] = address->a.val[5 - i];
    report.rssi = rssi;
    report.connectable = type == BT_GAP_ADV_TYPE_ADV_IND || type == BT_GAP_ADV_TYPE_ADV_DIRECT_IND;
    report.scan_response = type == BT_GAP_ADV_TYPE_SCAN_RSP;
    report.length = data->len;
    memcpy(report.data, data->data, data->len);
    if (self->reports.push(report)) {
      self->notify(kBleDiscovery);
    } else {
      self->error = -ENOBUFS;
      self->notify(kBleDiscoverOperationFailed);
      k_sem_give(&self->stop_);
    }
  }
  void entry() override {
    for (;;) {
      k_sem_take(&start_, K_FOREVER);
      {
        CallbackLock lock;
        if (shutdown_) return;
        current_scan = this;
      }
      int result = 0;
      bool stop_failed = false;
      if (duration_ != 0) {
        result = bt_le_scan_start(&parameters_, received);
        if (result == 0) {
          k_sem_take(&stop_, duration_ < 0 ? K_FOREVER : K_USEC(duration_));
          {
            CallbackLock lock;
            current_scan = null;
          }
          result = bt_le_scan_stop();
          stop_failed = result != 0;
        }
      }
      {
        CallbackLock lock;
        current_scan = null;
        if (result) {
          error = result;
        }
        if (stop_failed) controller_broken = true;
        active_ = false;
        notify(kBleCompleted | (error ? kBleDiscoverOperationFailed : 0));
        k_sem_give(&done_);
      }
    }
  }
  BleAdapterResource* adapter_;
  struct k_sem start_, stop_, done_;
  bt_le_scan_param parameters_ = {};
  int64 duration_ = 0;
  bool limited_ = false, active_ = false, shutdown_ = false, worker_started_ = false;
};

class BleRemoteDeviceResource : public BleGattResource {
 public:
  TAG(BleRemoteDeviceResource);
  BleRemoteDeviceResource(BleCentralManagerResource* manager, const bt_addr_le_t& address, bool secure)
      : BleGattResource(manager->resource_group(), REMOTE_DEVICE), manager_(manager), address_(address), secure_(secure) {
    k_sem_init(&changed_, 0, 1);
    ++manager_->devices;
    next_ = first_;
    first_ = this;
  }
  ~BleRemoteDeviceResource() override {
    // Cancel creation as well as established connections. A successful connect
    // can race with cancellation; wake on that callback and disconnect again.
    // No Toit/event lock is held while HCI commands or callbacks are awaited.
    int result = drain();
    {
      CallbackLock lock;
      if (result) {
        controller_broken = true;
        printf("[toit] Bluetooth connection cleanup failed: %d; reboot required\n", result);
      }
      auto link = &first_;
      while (*link != this) link = &(*link)->next_;
      *link = next_;
      --manager_->devices;
    }
    // Callbacks look up a live resource under callback_mutex. After unlinking,
    // even a delayed callback cannot access this resource or its parent.
  }
  int connect() {
    bt_conn_le_create_param create = BT_CONN_LE_CREATE_PARAM_INIT(
        BT_CONN_LE_OPT_NONE, BT_GAP_SCAN_FAST_INTERVAL, BT_GAP_SCAN_FAST_INTERVAL);
    create.timeout = 300;  // Three seconds, matching the ESP32 backend.
    bt_le_conn_param parameters = BT_LE_CONN_PARAM_INIT(24, 40, 0, 400);
    bt_conn* connection = null;
    int result = bt_conn_le_create(&address_, &create, &parameters, &connection);
    CallbackLock lock;
    connection_ = connection;
    if (result) terminal_ = true;
    return result;
  }
  int disconnect() {
    // Use the same drain for explicit close and destruction: cancelling an
    // initiating connection can instead produce a successful connection, in
    // which case we must issue a second disconnect before reporting completion.
    int result = drain();
    if (!result) {
      notify(kBleDisconnected);
    } else {
      CallbackLock lock;
      controller_broken = true;
    }
    return result;
  }
  static bool pending() {
    for (auto p = first_; p; p = p->next_) {
      if (!p->connected_ && !p->terminal_) return true;
    }
    return false;
  }
  static bool contains(const bt_addr_le_t& address) {
    for (auto p = first_; p; p = p->next_) {
      if (bt_addr_le_cmp(&p->address_, &address) == 0) return true;
    }
    return false;
  }
  static void connected(bt_conn* connection, uint8_t status) {
    {
      CallbackLock lock;
      auto self = lookup(connection);
      if (!self) return;
      self->connected_ = status == 0;
      self->terminal_ = status != 0;
      self->error = status ? -ECONNREFUSED : 0;
      k_sem_give(&self->changed_);
      if (status || !self->secure_) {
        self->notify(status ? kBleConnectFailed | kBleDisconnected : kBleConnected);
        return;
      }
#if CONFIG_TOIT_BLE_SECURITY
      self->bond_ready_ = bt_le_bond_exists(BT_ID_DEFAULT, bt_conn_get_dst(connection));
      bt_conn_ref(connection);
#endif
    }
#if CONFIG_TOIT_BLE_SECURITY
    // These calls can invoke callbacks. Retain only the connection across
    // them, never a resource pointer or callback/event lock.
    int result = bt_conn_auth_cb_overlay(connection, &authentication);
    if (!result) result = bt_conn_set_bondable(connection, true);
    if (!result) result = bt_conn_set_security(connection, BT_SECURITY_L2);
    if (result) security_failed(connection);
    bt_conn_unref(connection);
#endif
  }
#if CONFIG_TOIT_BLE_SECURITY
  static enum bt_security_err pairing_accept(bt_conn* connection, const bt_conn_pairing_feat* features) {
    CallbackLock lock;
    auto self = lookup(connection);
    if (!self || !self->secure_ || self->terminal_ || self->security_failed_) return BT_SECURITY_ERR_PAIR_NOT_ALLOWED;
    // A new pairing, including replacement of an old bond, must finish key
    // distribution before connect can report success. Core Vol 3, H 3.5.1:
    // AuthReq bit 3 selects SC; bonding bits 0..1 must equal 01.
    self->bond_ready_ = false;
    if (!features || (features->auth_req & 0x0b) != 0x09 || features->max_enc_key_size != 16) {
      return BT_SECURITY_ERR_AUTH_REQUIREMENT;
    }
    return BT_SECURITY_ERR_SUCCESS;
  }
  static void security_failed(bt_conn* connection) {
    {
      CallbackLock lock;
      auto self = lookup(connection);
      if (!self || !self->secure_ || self->terminal_) return;
      self->security_failed_ = true;
      self->error = -EACCES;
      self->notify(kBleConnectFailed);
    }
    // Also stop an established link if its security subsequently fails.
    bt_conn_disconnect(connection, BT_HCI_ERR_AUTH_FAIL);
  }
  static void security_changed(bt_conn* connection, bt_security_t level, enum bt_security_err status) {
    bt_conn_info info;
    if (status || level < BT_SECURITY_L2 || bt_conn_get_info(connection, &info) ||
        !(info.security.flags & BT_SECURITY_FLAG_SC) || info.security.enc_key_size != 16) {
      security_failed(connection);
      return;
    }
    CallbackLock lock;
    auto self = lookup(connection);
    if (!self || !self->secure_) return;
    self->encrypted_ = true;
    self->publish_secure();
  }
  static void pairing_complete(bt_conn* connection, bool bonded) {
    if (!bonded || !bt_le_bond_exists(BT_ID_DEFAULT, bt_conn_get_dst(connection))) {
      security_failed(connection);
      return;
    }
    CallbackLock lock;
    auto self = lookup(connection);
    if (!self || !self->secure_) return;
    self->bond_ready_ = true;
    self->publish_secure();
  }
  static void pairing_failed(bt_conn* connection, enum bt_security_err) { security_failed(connection); }
  static const bt_conn_auth_cb authentication;
#endif
  static void disconnected(bt_conn* connection, uint8_t reason) {
    (void)reason;
    CallbackLock lock;
    BleGattResource::disconnected(connection);
    auto self = lookup(connection);
    if (!self) return;
    self->terminal_ = true;
    self->notify(kBleDisconnected);
    k_sem_give(&self->changed_);
  }
 private:
#if CONFIG_TOIT_BLE_SECURITY
  void publish_secure() {  // callback_mutex held.
    if (!terminal_ && !security_failed_ && connected_ && encrypted_ && bond_ready_ && !secure_ready_) {
      secure_ready_ = true;
      notify(kBleConnected);
    }
  }
#endif
  static BleRemoteDeviceResource* lookup(bt_conn* connection) {
    bt_conn_info info;
    if (bt_conn_get_info(connection, &info) || info.role != BT_CONN_ROLE_CENTRAL) return null;
    for (auto p = first_; p; p = p->next_) {
      if (p->connection_ == connection) return p;
      // Zephyr can invoke connected before bt_conn_le_create returns its
      // reference. Identity address types are normalized before registration.
      if (!p->connection_ && bt_addr_le_cmp(&p->address_, bt_conn_get_dst(connection)) == 0) return p;
    }
    return null;
  }
  int drain() {
    int64_t deadline = k_uptime_get() + 5000;
    for (;;) {
      {
        CallbackLock lock;
        if (terminal_ || !connection_) return 0;
      }
      int result = bt_conn_disconnect(connection_, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
      // ENOTCONN can precede delivery of the terminal callback. Keep waiting
      // for it instead of assuming that the host has finished cleanup.
      if (result && result != -ENOTCONN) return result;
      int64_t remaining = deadline - k_uptime_get();
      if (remaining <= 0 || k_sem_take(&changed_, K_MSEC(remaining))) return -ETIMEDOUT;
    }
  }
  BleCentralManagerResource* manager_;
  bt_addr_le_t address_;
  bool connected_ = false, terminal_ = false;
  bool secure_;
#if CONFIG_TOIT_BLE_SECURITY
  bool encrypted_ = false, bond_ready_ = false, secure_ready_ = false, security_failed_ = false;
#endif
  struct k_sem changed_;
  BleRemoteDeviceResource* next_;
  static BleRemoteDeviceResource* first_;
};
BleRemoteDeviceResource* BleRemoteDeviceResource::first_ = null;
static bool connection_pending() { return BleRemoteDeviceResource::pending(); }
BT_CONN_CB_DEFINE(toit_connections) = {
  .connected = BleRemoteDeviceResource::connected,
  .disconnected = BleRemoteDeviceResource::disconnected,
#if CONFIG_TOIT_BLE_SECURITY
  .security_changed = BleRemoteDeviceResource::security_changed,
#endif
};
#if CONFIG_TOIT_BLE_SECURITY
const bt_conn_auth_cb BleRemoteDeviceResource::authentication = {
  .pairing_accept = BleRemoteDeviceResource::pairing_accept,
};
#endif

static BleLocalService* retired_services = null;
static unsigned local_attribute_count = 0;
static constexpr unsigned MAX_LOCAL_ATTRIBUTES = 64;
static void release_retired_services() {
  // This configuration's bt_disable aborts its dedicated RX thread after
  // closing HCI. No GATT traversal can still hold pointers into retired data.
  BUILD_ASSERT(IS_ENABLED(CONFIG_BT_RECV_WORKQ_BT), "GATT retirement requires the dedicated RX queue");
  CallbackLock lock;
  auto link = &retired_services;
  while (*link) {
    auto p = *link;
    if (p->registered) { controller_broken = true; link = &p->next; continue; }
    *link = p->next;
    local_attribute_count -= p->attribute_count;
    delete p;
  }
}

class BlePeripheralManagerResource : public BleCallbackResource, public Thread {
 public:
  TAG(BlePeripheralManagerResource);
  BlePeripheralManagerResource(ResourceGroup* group, BleAdapterResource* adapter, bool bonding, bool secure_connections)
      : BleCallbackResource(group, PERIPHERAL_MANAGER), Thread("BLE advertising"), adapter_(adapter),
        bonding_(bonding), secure_connections_(secure_connections) {
    k_sem_init(&changed_, 0, 1);
    k_sem_init(&advertise_work_, 0, 1);
    k_sem_init(&advertise_stopped_, 0, 1);
    adapter_->peripheral = true;
    ++adapter_->children;
    current_ = this;
    // Existing central-role connections can access this local GATT database.
    // Their security policy belongs to the central, so only adopt them here.
    bt_conn_foreach(BT_CONN_TYPE_LE, [](bt_conn* connection, void* context) {
      bt_conn_info info;
      if (!bt_conn_get_info(connection, &info) && info.state == BT_CONN_STATE_CONNECTED) {
        static_cast<BlePeripheralManagerResource*>(context)->adopt(connection);
      }
    }, this);
  }
  ~BlePeripheralManagerResource() override {
    int result = stop();
    { CallbackLock lock; shutdown_ = true; }
    if (worker_started_) { k_sem_give(&advertise_work_); join(); }
    if (!result) result = drain();
    CallbackLock lock;
    current_ = null;
    // Unregister now, but keep all native definitions until adapter shutdown.
    // GATT is bidirectional: a central-role link can have an access callback
    // in flight even after our incoming peripheral links have drained.
    for (auto p = services; p; p = p->next) ASSERT(p->wrappers == 0);
    while (services) {
      auto p = services;
      if (p->registered) {
        int unregister_result = bt_gatt_service_unregister(&p->definition);
        if (unregister_result) result = unregister_result;
        else p->registered = false;
      }
      services = p->next;
      p->next = retired_services;
      retired_services = p;
    }
    if (result) {
      controller_broken = true;
      printf("[toit] Bluetooth peripheral cleanup failed: %d; reboot required\n", result);
    }
    for (auto& peer : peers) if (peer.connection) bt_conn_unref(peer.connection);
    adapter_->peripheral = false;
    --adapter_->children;
  }
  bool initialize() { worker_started_ = spawn(); return worker_started_; }
  int start(const bt_le_adv_param& parameters, const Blob& data, const uint8_t* response, size_t response_length) {
    Locker event_lock(resource_group()->event_source()->mutex());
    CallbackLock lock;
    if (controller_broken) return -EIO;
    if (advertising) return -EALREADY;
    parameters_ = parameters;
    memcpy(advertisement_, data.address(), data.length());
    advertisement_length_ = data.length();
    if (response_length) memcpy(response_, response, response_length);
    response_length_ = response_length;
    clear_events(kBleAdvertiseStartSucceeded | kBleAdvertiseStartFailed);
    error = 0;
    advertising = initial_start_ = true;
    k_sem_give(&advertise_work_);
    return 0;
  }
  int stop() {
    if (!worker_started_) return 0;
    {
      CallbackLock lock;
      advertising = false;
      k_sem_reset(&advertise_stopped_);
      k_sem_give(&advertise_work_);
    }
    k_sem_take(&advertise_stopped_, K_FOREVER);
    return stop_error_;
  }
  struct Peer { bt_conn* connection = null; unsigned token = 0; };
  Peer peers[CONFIG_BT_MAX_CONN];
  BleLocalService* services = null;
  unsigned service_count = 0, attribute_count = 0;
  int reserved = -1, prepared = 0;
  bool advertising = false, started = false;
  static void connected(bt_conn* connection, uint8_t status) {
    bt_conn_info info;
    if (status || bt_conn_get_info(connection, &info) || info.state != BT_CONN_STATE_CONNECTED) return;
#if CONFIG_TOIT_BLE_SECURITY
    bool configure_security = false, bonding = false;
#endif
    {
      CallbackLock lock;
      if (current_) {
        current_->adopt(connection);
        if (info.role == BT_CONN_ROLE_PERIPHERAL) {
          ++current_->connections_seen_;
          current_->advertise_active_ = false;
          if (!current_->shutdown_) k_sem_give(&current_->advertise_work_);
#if CONFIG_TOIT_BLE_SECURITY
          configure_security = true;
          bonding = current_->bonding_;
          bt_conn_ref(connection);
#endif
        }
      }
    }
#if CONFIG_TOIT_BLE_SECURITY
    if (configure_security) {
      // Never hold a resource pointer or callback lock over host calls. An
      // ordinary peripheral also gets an overlay so it can reject pairing.
      int result = bt_conn_auth_cb_overlay(connection, &authentication);
      if (!result) result = bt_conn_set_bondable(connection, bonding);
      if (result) bt_conn_disconnect(connection, BT_HCI_ERR_AUTH_FAIL);
      bt_conn_unref(connection);
    }
#endif
  }
#if CONFIG_TOIT_BLE_SECURITY
  static enum bt_security_err pairing_accept(bt_conn* connection, const bt_conn_pairing_feat* features) {
    CallbackLock lock;
    auto self = security_owner(connection);
    if (!self || self->shutdown_ || !(self->bonding_ || self->secure_connections_)) {
      return BT_SECURITY_ERR_PAIR_NOT_ALLOWED;
    }
    // The API has no passkey/OOB UI. Support SC Just Works with full-size keys;
    // bonding remains optional and is negotiated per connection by the host.
    if (!features || !(features->auth_req & 0x08) || features->max_enc_key_size != 16) {
      return BT_SECURITY_ERR_AUTH_REQUIREMENT;
    }
    return BT_SECURITY_ERR_SUCCESS;
  }
  static void security_changed(bt_conn* connection, bt_security_t level, enum bt_security_err status) {
    bool reject;
    {
      CallbackLock lock;
      auto self = security_owner(connection);
      if (!self) return;
      bt_conn_info info;
      reject = self->shutdown_ || !(self->bonding_ || self->secure_connections_) || status ||
          level < BT_SECURITY_L2 || bt_conn_get_info(connection, &info) ||
          !(info.security.flags & BT_SECURITY_FLAG_SC) || info.security.enc_key_size != 16;
    }
    if (reject) bt_conn_disconnect(connection, BT_HCI_ERR_AUTH_FAIL);
  }
  static void pairing_complete(bt_conn* connection, bool bonded) {
    bool reject;
    {
      CallbackLock lock;
      auto self = security_owner(connection);
      if (!self) return;
      reject = self->shutdown_ || !(self->bonding_ || self->secure_connections_) ||
          (bonded && (!self->bonding_ || !bt_le_bond_exists(BT_ID_DEFAULT, bt_conn_get_dst(connection))));
    }
    if (reject) bt_conn_disconnect(connection, BT_HCI_ERR_AUTH_FAIL);
  }
  static void pairing_failed(bt_conn* connection, enum bt_security_err) {
    {
      CallbackLock lock;
      if (!security_owner(connection)) return;
    }
    bt_conn_disconnect(connection, BT_HCI_ERR_AUTH_FAIL);
  }
  static const bt_conn_auth_cb authentication;
#endif
  static void disconnected(bt_conn* connection, uint8_t reason) {
    USE(reason);
    CallbackLock lock;
    if (!current_) return;
    for (auto& peer : current_->peers) {
      if (peer.connection == connection) {
        peer.connection = null;
        bt_conn_unref(connection);
        k_sem_give(&current_->changed_);
        break;
      }
    }
  }
  static void recycled() {
    CallbackLock lock;
    if (current_ && !current_->shutdown_ && current_->advertising) k_sem_give(&current_->advertise_work_);
  }
 private:
#if CONFIG_TOIT_BLE_SECURITY
  static BlePeripheralManagerResource* security_owner(bt_conn* connection) {
    // Caller holds callback_mutex. Never apply peripheral policy to a link
    // owned by the central, even though it can access the local GATT database.
    bt_conn_info info;
    if (!current_ || bt_conn_get_info(connection, &info) || info.role != BT_CONN_ROLE_PERIPHERAL) return null;
    for (auto& peer : current_->peers) if (peer.connection == connection) return current_;
    return null;
  }
#endif
  static size_t fields(const uint8_t* data, size_t length, bt_data* fields) {
    size_t count = 0;
    for (size_t i = 0; i < length;) {
      unsigned size = data[i++];
      if (!size) break;
      fields[count].type = data[i];
      fields[count].data_len = size - 1;
      fields[count++].data = data + i + 1;
      i += size;
    }
    return count;
  }
  void entry() override {
    bool attempted_advertising = false;
    for (;;) {
      k_sem_take(&advertise_work_, K_FOREVER);
      bool wanted, initial;
      unsigned connections_seen;
      {
        CallbackLock lock;
        if (shutdown_) return;
        wanted = advertising;
        initial = initial_start_;
        connections_seen = connections_seen_;
        if (wanted && advertise_active_) continue;
      }
      if (!wanted) {
        int result = attempted_advertising ? bt_le_adv_stop() : 0;
        attempted_advertising = false;
        CallbackLock lock;
        if (initial_start_) { error = -ECANCELED; notify(kBleAdvertiseStartFailed); }
        advertise_active_ = initial_start_ = false;
        stop_error_ = result;
        if (result) controller_broken = true;
        k_sem_give(&advertise_stopped_);
        continue;
      }
      bt_data ad[16], response[16];
      size_t ad_count = fields(advertisement_, advertisement_length_, ad);
      size_t response_count = fields(response_, response_length_, response);
      attempted_advertising = true;
      int result = bt_le_adv_start(&parameters_, ad, ad_count, response_count ? response : null, response_count);
      {
        CallbackLock lock;
        advertise_active_ = !result && connections_seen == connections_seen_;
        if (initial && advertising) {
          initial_start_ = false;
          error = result;
          if (result) advertising = false;
          notify(result ? kBleAdvertiseStartFailed : kBleAdvertiseStartSucceeded);
        } else if (result && result != -ENOMEM && advertising) {
          error = result;
          advertising = false;
          printf("[toit] Bluetooth advertising restart failed: %d\n", result);
          notify(kBleAdvertiseStartFailed);
        }
      }
      if (result == -ENOMEM && !initial) k_sleep(K_MSEC(10));
      // Automatic restart can exhaust connection slots. Retry when the host
      // reports a recycled slot, not from the RX callback or in a busy loop.
    }
  }
  void adopt(bt_conn* connection) {
    for (auto& peer : peers) if (peer.connection == connection) return;
    for (auto& peer : peers) {
      if (!peer.connection) {
        peer.connection = bt_conn_ref(connection);
        peer.token = ++token_;  // Tokens are never reused during this manager's lifetime.
        k_sem_give(&changed_);
        return;
      }
    }
    UNREACHABLE();  // The host cannot have more than CONFIG_BT_MAX_CONN peers.
  }
  int drain() {
    // Reconcile with host state after stopping advertising, including a link
    // whose successful connection callback has not yet been delivered.
    bt_conn_foreach(BT_CONN_TYPE_LE, [](bt_conn* connection, void* data) {
      CallbackLock lock;
      bt_conn_info info;
      if (!bt_conn_get_info(connection, &info) && info.role == BT_CONN_ROLE_PERIPHERAL &&
          info.state != BT_CONN_STATE_DISCONNECTED) {
        static_cast<BlePeripheralManagerResource*>(data)->adopt(connection);
      }
    }, this);
    int64_t deadline = k_uptime_get() + 5000;
    for (;;) {
      bt_conn* connection = null;
      {
        CallbackLock lock;
        for (auto& peer : peers) {
          bt_conn_info info;
          if (peer.connection && !bt_conn_get_info(peer.connection, &info) && info.role == BT_CONN_ROLE_PERIPHERAL) {
            connection = bt_conn_ref(peer.connection);
            break;
          }
        }
      }
      if (!connection) return 0;
      int result = bt_conn_disconnect(connection, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
      bt_conn_unref(connection);
      if (result && result != -ENOTCONN) return result;
      int64_t remaining = deadline - k_uptime_get();
      if (remaining <= 0 || k_sem_take(&changed_, K_MSEC(remaining))) return -ETIMEDOUT;
    }
  }
  BleAdapterResource* adapter_;
  bool bonding_, secure_connections_;
  struct k_sem changed_, advertise_work_, advertise_stopped_;
  bt_le_adv_param parameters_ = {};
  uint8_t advertisement_[31], response_[31];
  size_t advertisement_length_ = 0, response_length_ = 0;
  bool worker_started_ = false, shutdown_ = false, initial_start_ = false, advertise_active_ = false;
  unsigned connections_seen_ = 0;
  int stop_error_ = 0;
  unsigned token_ = 0;
  static BlePeripheralManagerResource* current_;
};
BlePeripheralManagerResource* BlePeripheralManagerResource::current_ = null;
BT_CONN_CB_DEFINE(toit_peripheral_connections) = {
  .connected = BlePeripheralManagerResource::connected,
  .disconnected = BlePeripheralManagerResource::disconnected,
  .recycled = BlePeripheralManagerResource::recycled,
#if CONFIG_TOIT_BLE_SECURITY
  .security_changed = BlePeripheralManagerResource::security_changed,
#endif
};
#if CONFIG_TOIT_BLE_SECURITY
const bt_conn_auth_cb BlePeripheralManagerResource::authentication = {
  .pairing_accept = BlePeripheralManagerResource::pairing_accept,
};
static bt_conn_auth_info_cb security_callbacks = {
  .pairing_complete = [](bt_conn* connection, bool bonded) {
    BleRemoteDeviceResource::pairing_complete(connection, bonded);
    BlePeripheralManagerResource::pairing_complete(connection, bonded);
  },
  .pairing_failed = [](bt_conn* connection, enum bt_security_err error) {
    BleRemoteDeviceResource::pairing_failed(connection, error);
    BlePeripheralManagerResource::pairing_failed(connection, error);
  },
};
static int register_security_callbacks() {
  // Static callbacks survive bt_disable. Adapter initialization is serialized,
  // so register once rather than appending this node on every reopen.
  static bool registered = false;
  if (registered) return 0;
  int result = bt_conn_auth_info_cb_register(&security_callbacks);
  if (!result) registered = true;
  return result;
}
#endif

class BleServiceResource : public BleCallbackResource {
 public:
  TAG(BleServiceResource);
  BleServiceResource(ResourceGroup* group, BleLocalService* data)
      : BleCallbackResource(group, SERVICE), data(data) {}
  ~BleServiceResource() override { CallbackLock lock; --data->wrappers; }
  BleLocalService* data;
};
class BleReadWriteElement : public BleCallbackResource {
 public:
  TAGS(BleReadWriteElement);
  BleReadWriteElement(ResourceGroup* group, Kind kind, BleLocalAttribute* data)
      : BleCallbackResource(group, kind), data(data) {
    data->owner = this;
    data->characteristic = kind == CHARACTERISTIC;
    data->notify_received = [](void* owner) {
      static_cast<BleReadWriteElement*>(owner)->notify(kBleDataReceived);
    };
    ++data->service->wrappers;
  }
  ~BleReadWriteElement() override {
    CallbackLock lock;
    data->owner = null;
    --data->service->wrappers;
  }
  BleLocalAttribute* data;
};
class BleCharacteristicResource : public BleReadWriteElement {
 public:
  TAG(BleCharacteristicResource);
  BleCharacteristicResource(ResourceGroup* group, BleLocalAttribute* data)
      : BleReadWriteElement(group, CHARACTERISTIC, data) {}
};
class BleDescriptorResource : public BleReadWriteElement {
 public:
  TAG(BleDescriptorResource);
  BleDescriptorResource(ResourceGroup* group, BleLocalAttribute* data)
      : BleReadWriteElement(group, DESCRIPTOR, data) {}
};

class BleResourceGroup : public ResourceGroup {
 public:
  TAG(BleResourceGroup);
  explicit BleResourceGroup(Process* process) : ResourceGroup(process, ZephyrEventSource::instance()) {}
  uint32_t on_event(Resource*, word data, uint32_t state) override { return state | data; }
};

MODULE_IMPLEMENTATION(ble, MODULE_BLE)
PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new BleResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}
PRIMITIVE(create_adapter) {
  ARGS(BleResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  BleAdapterResource* adapter;
  {
    CallbackLock lock;
    if (controller_broken) FAIL(INVALID_STATE);
    if (adapter_claimed) FAIL(ALREADY_IN_USE);
    adapter = _new BleAdapterResource(group);
    if (!adapter) FAIL(MALLOC_FAILED);
    adapter_claimed = true;
  }
  group->register_resource(adapter);
  if (!adapter->initialize()) { group->unregister_resource(adapter); FAIL(MALLOC_FAILED); }
  proxy->set_external_address(adapter);
  return proxy;
}
PRIMITIVE(create_central_manager) {
  ARGS(BleAdapterResource, adapter);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  BleCentralManagerResource* manager;
  {
    CallbackLock lock;
    if (!adapter->ready) FAIL(INVALID_STATE);
    if (adapter->central) FAIL(ALREADY_IN_USE);
    manager = _new BleCentralManagerResource(adapter->resource_group(), adapter);
    if (!manager) FAIL(MALLOC_FAILED);
  }
  adapter->resource_group()->register_resource(manager);
  if (!manager->initialize()) { adapter->resource_group()->unregister_resource(manager); FAIL(MALLOC_FAILED); }
  proxy->set_external_address(manager);
  manager->notify(kBleStarted);
  return proxy;
}
PRIMITIVE(create_peripheral_manager) {
  ARGS(BleAdapterResource, adapter, bool, bonding, bool, secure_connections);
  if ((bonding || secure_connections) && !IS_ENABLED(CONFIG_TOIT_BLE_SECURITY)) FAIL(UNIMPLEMENTED);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  BlePeripheralManagerResource* manager;
  {
    CallbackLock lock;
    if (!adapter->ready) FAIL(INVALID_STATE);
    if (adapter->peripheral) FAIL(ALREADY_IN_USE);
    manager = _new BlePeripheralManagerResource(adapter->resource_group(), adapter, bonding, secure_connections);
    if (!manager) FAIL(MALLOC_FAILED);
  }
  adapter->resource_group()->register_resource(manager);
  if (!manager->initialize()) { adapter->resource_group()->unregister_resource(manager); FAIL(MALLOC_FAILED); }
  proxy->set_external_address(manager);
  manager->notify(kBleStarted);
  return proxy;
}
PRIMITIVE(close) {
  ARGS(BleResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(release_resource) {
  ARGS(BleResource, resource);
  {
    CallbackLock lock;
    if (resource->kind() == BleResource::ADAPTER &&
        static_cast<BleAdapterResource*>(resource)->children) FAIL(ALREADY_IN_USE);
    if (resource->kind() == BleResource::CENTRAL_MANAGER &&
        static_cast<BleCentralManagerResource*>(resource)->devices) FAIL(ALREADY_IN_USE);
    if (resource->kind() == BleResource::PERIPHERAL_MANAGER) {
      for (auto service = static_cast<BlePeripheralManagerResource*>(resource)->services; service; service = service->next) {
        if (service->wrappers) FAIL(ALREADY_IN_USE);
      }
    }
    if (resource_proxy->external_tag() == BleServiceResourceTag &&
        static_cast<BleServiceResource*>(resource)->data->wrappers > 1) FAIL(ALREADY_IN_USE);
  }
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(scan_start) {
  ARGS(BleCentralManagerResource, manager, bool, passive, int64, duration_us,
       int, interval, int, window, bool, limited);
  if (interval == 0) interval = BT_GAP_SCAN_FAST_INTERVAL;
  if (window == 0) window = Utils::min(interval, BT_GAP_SCAN_FAST_WINDOW);
  if (interval < 4 || interval > 16384 || window < 4 || window > interval ||
      duration_us < -1 || duration_us > INT64_C(2147483647000)) FAIL(INVALID_ARGUMENT);
  bt_le_scan_param parameters = {};
  parameters.type = passive ? BT_LE_SCAN_TYPE_PASSIVE : BT_LE_SCAN_TYPE_ACTIVE;
  parameters.interval = interval;
  parameters.window = window;
  int result = manager->start(parameters, duration_us, limited);
  if (result == -EALREADY) FAIL(ALREADY_EXISTS);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(scan_stop) {
  ARGS(BleCentralManagerResource, manager);
  manager->stop();
  return process->null_object();
}
PRIMITIVE(scan_next) {
  ARGS(BleCentralManagerResource, manager);
  CallbackLock lock;
  const auto report = manager->reports.peek();
  if (!report) return process->null_object();
  Array* result = process->object_heap()->allocate_array(5, process->null_object());
  if (!result) FAIL(ALLOCATION_FAILED);
  ByteArray* address = process->object_heap()->allocate_internal_byte_array(7);
  if (!address) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes address_bytes(address);
  memcpy(address_bytes.address(), report->address, 7);
  result->at_put(0, address);
  result->at_put(1, Smi::from(report->rssi));
  if (report->length) {
    ByteArray* data = process->object_heap()->allocate_internal_byte_array(report->length);
    if (!data) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes bytes(data);
    memcpy(bytes.address(), report->data, report->length);
    result->at_put(2, data);
  }
  result->at_put(3, BOOL(report->connectable));
  result->at_put(4, BOOL(report->scan_response));
  manager->reports.pop();
  return result;
}

PRIMITIVE(advertise_start_raw) {
  ARGS(BlePeripheralManagerResource, manager, Blob, data, Object, scan_response,
       int, interval_us, int, connection_mode);
  {
    CallbackLock lock;
    if (controller_broken) FAIL(INVALID_STATE);
  }
  if (connection_mode == 1) FAIL(UNIMPLEMENTED);  // The shared API does not provide a directed peer address.
  if (connection_mode != 0 && connection_mode != 2) FAIL(INVALID_ARGUMENT);
  if (connection_mode == 2 && manager->service_count && !manager->started) FAIL(INVALID_STATE);
  if (interval_us < 20000 || interval_us / 625 > 16384) FAIL(INVALID_ARGUMENT);
  if (!ble_zephyr_valid_ad(data.address(), data.length())) FAIL(INVALID_ARGUMENT);
  const uint8_t* response_data = null;
  size_t response_length = 0;
  if (scan_response != process->null_object()) {
    Blob bytes;
    if (!scan_response->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
    if (!ble_zephyr_valid_ad(bytes.address(), bytes.length())) FAIL(INVALID_ARGUMENT);
    response_data = bytes.address();
    response_length = bytes.length();
  }
  bt_le_adv_param parameters = {};
  parameters.id = BT_ID_DEFAULT;
  parameters.options = BT_LE_ADV_OPT_USE_IDENTITY;
  if (connection_mode == 2) parameters.options |= BT_LE_ADV_OPT_CONN;
  parameters.interval_min = parameters.interval_max = interval_us / 625;
  int result = manager->start(parameters, data, response_data, response_length);
  if (result == -EALREADY) FAIL(ALREADY_EXISTS);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(advertise_stop) {
  ARGS(BlePeripheralManagerResource, manager);
  int result = manager->stop();
  if (result) return Primitive::os_error(result < 0 ? -result : EIO, process);
  return process->null_object();
}
PRIMITIVE(set_gap_device_name) {
  ARGS(BleAdapterResource, adapter, cstring, name);
  USE(adapter);
  int result = bt_set_name(name);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
static Object* ble_operation_error(Process* process, int error) {
  if (!error) FAIL(INVALID_STATE);
  if (error == -ENOBUFS) FAIL(QUOTA_EXCEEDED);
  if (error == -EMSGSIZE) FAIL(OUT_OF_RANGE);
  if (error > 0) {
    char message[48];
    snprintf(message, sizeof(message), "Bluetooth ATT error 0x%02x", error);
    String* result = process->allocate_string(message);
    if (!result) FAIL(ALLOCATION_FAILED);
    return Primitive::mark_as_error(result);
  }
  return Primitive::os_error(-error, process);
}
PRIMITIVE(get_error) {
  ARGS(BleCallbackResource, resource, bool, is_oom);
  USE(is_oom);
  CallbackLock lock;
  return ble_operation_error(process, resource->error);
}
PRIMITIVE(clear_error) {
  ARGS(BleCallbackResource, resource, bool, is_oom);
  USE(is_oom);
  CallbackLock lock;
  resource->error = 0;
  return process->null_object();
}
PRIMITIVE(get_bonded_peers) {
  ARGS(BleCentralManagerResource, manager);
  USE(manager);
  unsigned count = 0;
#if CONFIG_TOIT_BLE_SECURITY
  struct Snapshot {
    bt_addr_le_t peers[CONFIG_BT_MAX_PAIRED];
    unsigned count = 0;
  } snapshot;
  // Key updates run on Zephyr threads, not interrupts. Copy a bounded snapshot
  // without preemption, then allocate Toit objects after unlocking scheduling.
  k_sched_lock();
  bt_foreach_bond(BT_ID_DEFAULT, [](const bt_bond_info* bond, void* context) {
    auto snapshot = static_cast<Snapshot*>(context);
    if (snapshot->count < CONFIG_BT_MAX_PAIRED) snapshot->peers[snapshot->count++] = bond->addr;
  }, &snapshot);
  k_sched_unlock();
  count = snapshot.count;
#endif
  Array* result = process->object_heap()->allocate_array(count, process->null_object());
  if (!result) FAIL(ALLOCATION_FAILED);
#if CONFIG_TOIT_BLE_SECURITY
  for (unsigned i = 0; i < count; ++i) {
    ByteArray* address = process->allocate_byte_array(7);
    if (!address) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes bytes(address);
    bytes.address()[0] = snapshot.peers[i].type;
    for (int j = 0; j < 6; ++j) bytes.address()[j + 1] = snapshot.peers[i].a.val[5 - j];
    result->at_put(i, address);
  }
#endif
  return result;
}

PRIMITIVE(connect) {
  ARGS(BleCentralManagerResource, manager, Blob, address, bool, secure_connection);
  if (secure_connection && !IS_ENABLED(CONFIG_TOIT_BLE_SECURITY)) FAIL(UNIMPLEMENTED);
  if (address.length() != 7 || address.address()[0] > BT_ADDR_LE_RANDOM_ID) FAIL(INVALID_ARGUMENT);
  bt_addr_le_t peer;
  // Zephyr resolves identity address types to public/random before callbacks.
  peer.type = address.address()[0] & 1;
  for (int i = 0; i < 6; ++i) peer.a.val[i] = address.address()[6 - i];
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  BleRemoteDeviceResource* device;
  {
    CallbackLock lock;
    if (controller_broken) FAIL(INVALID_STATE);
    if (manager->scanning() || connection_pending() || BleRemoteDeviceResource::contains(peer)) FAIL(ALREADY_IN_USE);
    device = _new BleRemoteDeviceResource(manager, peer, secure_connection);
    if (!device) FAIL(MALLOC_FAILED);
  }
  manager->resource_group()->register_resource(device);
  int result = device->connect();
  if (result) {
    manager->resource_group()->unregister_resource(device);
    return Primitive::os_error(-result, process);
  }
  proxy->set_external_address(device);
  return proxy;
}
PRIMITIVE(disconnect) {
  ARGS(BleRemoteDeviceResource, device);
  int result = device->disconnect();
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(get_att_mtu) {
  ARGS(BleGattResource, resource);
  return Smi::from(bt_gatt_get_mtu(resource->connection()));
}

static Object* discover_filtered(Process* process, BleGattResource* resource, Array* filters,
                                 uint8_t type, uint16_t start, uint16_t end) {
  if (filters->length() > 1) FAIL(INVALID_ARGUMENT);
  BleZephyrUuid filter;
  if (filters->length()) {
    Blob bytes;
    if (!filters->at(0)->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
    if (!filter.set(bytes.address(), bytes.length())) FAIL(INVALID_ARGUMENT);
  }
  int result = resource->discover(type, start, end, filter);
  if (result == -EALREADY) FAIL(ALREADY_IN_USE);
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}

static Object* discovery_result(Process* process, BleGattResource* resource, BleResource::Kind kind) {
  BleGattDiscovery* operation;
  {
    CallbackLock lock;
    operation = resource->discovery;
    if (!operation || operation->active || operation->result_kind != kind) FAIL(INVALID_STATE);
    if (operation->error == -ENOBUFS) FAIL(QUOTA_EXCEEDED);
    if (operation->error) return Primitive::os_error(-operation->error, process);
  }
  // A completed operation is immutable. The primitive owns the process thread,
  // so no close/start can replace it while allocations below are being made.
  unsigned count = 0;
  for (unsigned i = 0; i < operation->attributes.count; ++i) {
    const auto& record = operation->attributes.records[i];
    if (!operation->filter.length || operation->filter.equals(record.uuid)) ++count;
  }
  Array* result = process->object_heap()->allocate_array(count, process->null_object());
  if (!result) FAIL(ALLOCATION_FAILED);
  BleGattAttributeResource* attributes[BleZephyrAttributes::CAPACITY] = {};
  bool committed = false;
  Defer cleanup{[&] {
    if (!committed) for (auto attribute : attributes) delete attribute;
  }};
  unsigned index = 0;
  bool characteristic = kind == BleResource::CHARACTERISTIC;
  for (unsigned i = 0; i < operation->attributes.count; ++i) {
    auto record = operation->attributes.records[i];
    if (operation->filter.length) {
      if (!operation->filter.equals(record.uuid)) continue;
      record.uuid = operation->filter;
    }
    Array* info = process->object_heap()->allocate_array(characteristic ? 3 : 2, process->null_object());
    if (!info) FAIL(ALLOCATION_FAILED);
    ByteArray* uuid = process->object_heap()->allocate_internal_byte_array(record.uuid.length);
    if (!uuid) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes bytes(uuid);
    memcpy(bytes.address(), record.uuid.bytes, record.uuid.length);
    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (!proxy) FAIL(ALLOCATION_FAILED);
    info->at_put(0, uuid);
    if (characteristic) info->at_put(1, Smi::from(record.properties));
    info->at_put(characteristic ? 2 : 1, proxy);
    result->at_put(index, info);
    {
      CallbackLock lock;
      attributes[index] = _new BleGattAttributeResource(resource, kind, record);
    }
    if (!attributes[index]) FAIL(MALLOC_FAILED);
    ++index;
  }
  // Publish only after every Toit and native allocation succeeds. Allocation
  // failure therefore leaves the results intact for a GC/retry and no orphan
  // native resources registered in the group.
  for (unsigned i = 0; i < count; ++i) {
    auto info = Array::cast(result->at(i));
    auto proxy = ByteArray::cast(info->at(characteristic ? 2 : 1));
    resource->resource_group()->register_resource(attributes[i]);
    proxy->set_external_address(attributes[i]);
  }
  committed = true;
  if (kind == BleResource::DESCRIPTOR) {
    auto characteristic = static_cast<BleGattAttributeResource*>(resource);
    BleZephyrUuid ccc;
    const uint8_t uuid[] = {0x29, 0x02};
    ccc.set(uuid, sizeof(uuid));
    characteristic->ccc_handle = 0;
    for (unsigned i = 0; i < count; ++i) {
      if (attributes[i]->attribute.uuid.equals(ccc)) {
        characteristic->ccc_handle = attributes[i]->attribute.value;
        break;
      }
    }
  }
  resource->discard_discovery();
  return result;
}

PRIMITIVE(discover_services) {
  ARGS(BleRemoteDeviceResource, device, Array, filters);
  return discover_filtered(process, device, filters, BT_GATT_DISCOVER_PRIMARY, 1, UINT16_MAX);
}
PRIMITIVE(discover_services_result) {
  ARGS(BleRemoteDeviceResource, device);
  return discovery_result(process, device, BleResource::SERVICE);
}
PRIMITIVE(discover_characteristics) {
  ARGS(BleGattAttributeResource, service, Array, filters);
  if (service->kind() != BleResource::SERVICE) FAIL(INVALID_ARGUMENT);
  return discover_filtered(process, service, filters, BT_GATT_DISCOVER_CHARACTERISTIC,
      service->attribute.start, service->attribute.end);
}
PRIMITIVE(discover_characteristics_result) {
  ARGS(BleGattAttributeResource, service);
  if (service->kind() != BleResource::SERVICE) FAIL(INVALID_ARGUMENT);
  return discovery_result(process, service, BleResource::CHARACTERISTIC);
}
PRIMITIVE(discover_descriptors) {
  ARGS(BleGattAttributeResource, characteristic);
  if (characteristic->kind() != BleResource::CHARACTERISTIC) FAIL(INVALID_ARGUMENT);
  const auto& record = characteristic->attribute;
  // An empty range completes locally, avoiding both handle wraparound and a
  // request that could accidentally include the next characteristic's CCCD.
  uint16_t start = record.value < record.end ? record.value + 1 : 1;
  uint16_t end = record.value < record.end ? record.end : 0;
  int result = characteristic->discover(BT_GATT_DISCOVER_DESCRIPTOR, start, end, BleZephyrUuid());
  if (result == -EALREADY) FAIL(ALREADY_IN_USE);
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(discover_descriptors_result) {
  ARGS(BleGattAttributeResource, characteristic);
  if (characteristic->kind() != BleResource::CHARACTERISTIC) FAIL(INVALID_ARGUMENT);
  return discovery_result(process, characteristic, BleResource::DESCRIPTOR);
}
PRIMITIVE(handle) {
  ARGS(BleResource, attribute);
  if (attribute->kind() != BleResource::CHARACTERISTIC && attribute->kind() != BleResource::DESCRIPTOR) FAIL(INVALID_ARGUMENT);
  if (attribute_proxy->external_tag() >= BleReadWriteElementMinTag && attribute_proxy->external_tag() <= BleReadWriteElementMaxTag) {
    auto data = static_cast<BleReadWriteElement*>(attribute)->data;
    if (!data->deployed || !data->service->registered) FAIL(INVALID_STATE);
    return Smi::from(data->deployed->handle);
  }
  if (attribute_proxy->external_tag() != BleGattAttributeResourceTag) FAIL(INVALID_ARGUMENT);
  return Smi::from(static_cast<BleGattAttributeResource*>(attribute)->attribute.value);
}

PRIMITIVE(request_read) {
  ARGS(BleGattAttributeResource, attribute);
  if (attribute->kind() != BleResource::CHARACTERISTIC && attribute->kind() != BleResource::DESCRIPTOR) FAIL(INVALID_ARGUMENT);
  int result = attribute->start_value(false);
  if (result == -EALREADY) FAIL(ALREADY_IN_USE);
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(get_value) {
  ARGS(BleCallbackResource, resource);
  CallbackLock lock;
  if (resource_proxy->external_tag() >= BleReadWriteElementMinTag && resource_proxy->external_tag() <= BleReadWriteElementMaxTag) {
    auto data = static_cast<BleReadWriteElement*>(resource)->data;
    if (!data->received) FAIL(INVALID_ARGUMENT);
    if (data->receive_error) {
      int error = data->receive_error;
      data->receive_error = 0;
      return ble_operation_error(process, error);
    }
    auto value = data->received->peek();
    if (!value) return process->null_object();
    ByteArray* result = process->object_heap()->allocate_internal_byte_array(value->length);
    if (!result) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes bytes(result);
    memcpy(bytes.address(), value->bytes, value->length);
    data->received->pop();
    return result;
  }
  if (resource_proxy->external_tag() != BleGattAttributeResourceTag) FAIL(INVALID_ARGUMENT);
  auto attribute = static_cast<BleGattAttributeResource*>(resource);
  auto operation = attribute->read;
  if (!operation || operation->active) return process->null_object();
  if (operation->error) return ble_operation_error(process, operation->error);
  ByteArray* result = process->object_heap()->allocate_internal_byte_array(operation->value.length);
  if (!result) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), operation->value.bytes, operation->value.length);
  attribute->read = null;
  operation->owner = null;
  operation->release();
  return result;
}
PRIMITIVE(write_value) {
  ARGS(BleGattAttributeResource, attribute, Blob, value, bool, with_response, bool, allow_retry);
  if (attribute->kind() != BleResource::CHARACTERISTIC && attribute->kind() != BleResource::DESCRIPTOR) FAIL(INVALID_ARGUMENT);
  {
    CallbackLock lock;
    bt_conn_info info;
    if (controller_broken) FAIL(INVALID_STATE);
    if (bt_conn_get_info(attribute->connection(), &info) || info.state != BT_CONN_STATE_CONNECTED) {
      return Primitive::os_error(ENOTCONN, process);
    }
    if (attribute->operation_busy()) FAIL(ALREADY_IN_USE);
  }
  unsigned mtu = bt_gatt_get_mtu(attribute->connection());
  size_t length = value.length();
  if (mtu < 3 || length > mtu - 3 || length > BleZephyrValue::CAPACITY) FAIL(OUT_OF_RANGE);
  // Write Request retains a stable native copy. Write Command copies into a
  // Zephyr TX buffer before returning and retains no pointer into the VM heap.
  int result = with_response
      ? attribute->start_value(true, value.address(), value.length())
      : bt_gatt_write_without_response(attribute->connection(), attribute->attribute.value,
          value.address(), value.length(), false);
  if (result == -ENOMEM && allow_retry) FAIL(QUOTA_EXCEEDED);
  if (result == -EALREADY) FAIL(ALREADY_IN_USE);
  if (result) return Primitive::os_error(-result, process);
  return Smi::from(with_response ? 1 : 0);
}
PRIMITIVE(cancel_operation) {
  ARGS(BleGattResource, resource, int, operation);
  if (operation == 0) {
    resource->discard_discovery();
  } else if (operation == 1 || operation == 2) {
    if (resource->kind() != BleResource::CHARACTERISTIC && resource->kind() != BleResource::DESCRIPTOR) FAIL(INVALID_ARGUMENT);
    static_cast<BleGattAttributeResource*>(resource)->discard_value(operation == 2);
  } else if (operation == 3) {
    if (resource->kind() != BleResource::CHARACTERISTIC) FAIL(INVALID_ARGUMENT);
    static_cast<BleGattAttributeResource*>(resource)->cancel_subscription();
  } else {
    FAIL(INVALID_ARGUMENT);
  }
  return process->null_object();
}

PRIMITIVE(set_characteristic_notify) {
  ARGS(BleGattAttributeResource, characteristic, bool, enable);
  if (characteristic->kind() != BleResource::CHARACTERISTIC ||
      !(characteristic->attribute.properties & (BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE))) FAIL(INVALID_ARGUMENT);
  int result = characteristic->configure_subscription(enable);
  if (result == -EALREADY) FAIL(ALREADY_IN_USE);
  if (result == -EBUSY || result == -ENOMEM || result == -ENOSPC) FAIL(QUOTA_EXCEEDED);
  if (result == -ENOENT) FAIL(INVALID_ARGUMENT);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(get_notification) {
  ARGS(BleGattAttributeResource, characteristic);
  if (characteristic->kind() != BleResource::CHARACTERISTIC) FAIL(INVALID_ARGUMENT);
  CallbackLock lock;
  auto route = characteristic->subscription;
  if (!route) FAIL(INVALID_STATE);
  if (route->notification_error) return ble_operation_error(process, route->notification_error);
  if (!route->enabled || !route->registered) FAIL(INVALID_STATE);
  auto value = route->notifications.peek();
  if (!value) return process->null_object();
  ByteArray* result = process->object_heap()->allocate_internal_byte_array(value->length);
  if (!result) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), value->bytes, value->length);
  route->notifications.pop();
  return result;
}

static Object* local_value(Process* process, Object* object, BleZephyrValue* value, bool* present) {
  *present = object != process->null_object();
  value->length = 0;
  if (!*present) return null;
  Blob bytes;
  if (!object->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
  if (!value->append(bytes.address(), bytes.length())) FAIL(OUT_OF_RANGE);
  return null;
}
PRIMITIVE(add_service) {
  ARGS(BlePeripheralManagerResource, manager, Blob, uuid);
  BleLocalUuid native_uuid = {};
  if (!native_uuid.set(uuid.address(), uuid.length())) FAIL(INVALID_ARGUMENT);
  if (!bt_uuid_cmp(&native_uuid.uuid, BT_UUID_GAP) || !bt_uuid_cmp(&native_uuid.uuid, BT_UUID_GATT)) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  BleServiceResource* resource;
  {
    CallbackLock lock;
    if (controller_broken || manager->reserved >= 0 || manager->started) FAIL(INVALID_STATE);
    if (local_attribute_count == MAX_LOCAL_ATTRIBUTES || manager->service_count == 16) FAIL(QUOTA_EXCEEDED);
    auto data = _new BleLocalService(manager);
    if (!data) FAIL(MALLOC_FAILED);
    resource = _new BleServiceResource(manager->resource_group(), data);
    if (!resource) { delete data; FAIL(MALLOC_FAILED); }
    data->uuid = native_uuid;
    auto link = &manager->services;
    while (*link) link = &(*link)->next;
    *link = data;
    ++manager->service_count;
    ++manager->attribute_count;
    ++local_attribute_count;
  }
  manager->resource_group()->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}
static Object* add_local_attribute(Process* process, ResourceGroup* group, BleLocalService* service,
    BleLocalAttribute* parent, const Blob& uuid, int properties, int permissions, Object* value) {
  if (!BleLocalAttribute::valid_properties(properties, parent != null) ||
      permissions < 0 || (permissions & ~0xf)) FAIL(INVALID_ARGUMENT);
  BleLocalUuid native_uuid = {};
  if (!native_uuid.set(uuid.address(), uuid.length())) FAIL(INVALID_ARGUMENT);
  // Declarations and the stack-owned CCC must not be supplied as user values.
  if (!bt_uuid_cmp(&native_uuid.uuid, BT_UUID_GATT_PRIMARY) ||
      !bt_uuid_cmp(&native_uuid.uuid, BT_UUID_GATT_SECONDARY) ||
      !bt_uuid_cmp(&native_uuid.uuid, BT_UUID_GATT_INCLUDE) ||
      !bt_uuid_cmp(&native_uuid.uuid, BT_UUID_GATT_CHRC) ||
      !bt_uuid_cmp(&native_uuid.uuid, BT_UUID_GATT_CCC)) FAIL(INVALID_ARGUMENT);
  if (!parent) {
    if ((permissions & 5) && !(properties & (BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE))) FAIL(INVALID_ARGUMENT);
    if ((permissions & 10) && !(properties & (BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP))) FAIL(INVALID_ARGUMENT);
  }
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto data = _new BleLocalAttribute(service, properties, permissions);
  if (!data) FAIL(MALLOC_FAILED);
  bool committed = false;
  Defer cleanup{[&] { if (!committed) delete data; }};
  Object* error = local_value(process, value, &data->value, &data->has_value);
  if (error) return error;
  data->uuid = native_uuid;
  if (permissions & 10) {
    data->received = _new BleZephyrNotifications;
    if (!data->received) FAIL(MALLOC_FAILED);
  }
  unsigned count = parent ? 1 : 2 + ((properties & (BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE)) ? 1 : 0);
  BleReadWriteElement* resource;
  {
    CallbackLock lock;
    if (controller_broken || service->manager->reserved >= 0 || service->prepared) FAIL(INVALID_STATE);
    if (count > MAX_LOCAL_ATTRIBUTES - local_attribute_count) FAIL(QUOTA_EXCEEDED);
    if (parent) {
      for (auto p = parent->descriptors; p; p = p->next) {
        if (!bt_uuid_cmp(&p->uuid.uuid, &native_uuid.uuid)) FAIL(ALREADY_EXISTS);
      }
    }
    if (parent) resource = _new BleDescriptorResource(group, data);
    else resource = _new BleCharacteristicResource(group, data);
    if (!resource) FAIL(MALLOC_FAILED);
    auto link = parent ? &parent->descriptors : &service->characteristics;
    while (*link) link = &(*link)->next;
    *link = data;
    service->attribute_count += count;
    service->manager->attribute_count += count;
    local_attribute_count += count;
    committed = true;
  }
  group->register_resource(resource);
  if (parent) proxy->set_external_address(static_cast<BleDescriptorResource*>(resource));
  else proxy->set_external_address(static_cast<BleCharacteristicResource*>(resource));
  return proxy;
}
PRIMITIVE(add_characteristic) {
  ARGS(BleServiceResource, service, Blob, uuid, int, properties, int, permissions, Object, value);
  return add_local_attribute(process, service->resource_group(), service->data, null, uuid, properties, permissions, value);
}
PRIMITIVE(add_descriptor) {
  ARGS(BleCharacteristicResource, characteristic, Blob, uuid, int, properties, int, permissions, Object, value);
  return add_local_attribute(process, characteristic->resource_group(), characteristic->data->service,
      characteristic->data, uuid, properties, permissions, value);
}
PRIMITIVE(reserve_services) {
  ARGS(BlePeripheralManagerResource, manager, int, count);
  CallbackLock lock;
  if (count < 0 || static_cast<unsigned>(count) != manager->service_count) FAIL(INVALID_ARGUMENT);
  if (controller_broken || manager->reserved >= 0 || manager->advertising) FAIL(INVALID_STATE);
  manager->reserved = count;
  return process->null_object();
}
PRIMITIVE(deploy_service) {
  ARGS(BleServiceResource, service, int, index);
  CallbackLock lock;
  auto data = service->data;
  auto manager = data->manager;
  if (controller_broken || data->prepared || manager->started) FAIL(INVALID_STATE);
  if (index != manager->prepared || index < 0 || index >= manager->reserved) FAIL(INVALID_ARGUMENT);
  int result = data->prepare();
  if (result) FAIL(MALLOC_FAILED);
  ++manager->prepared;
  service->notify(kBleServiceAddSucceeded);
  return process->null_object();
}
PRIMITIVE(start_gatt_server) {
  ARGS(BlePeripheralManagerResource, manager);
  CallbackLock lock;
  if (controller_broken || manager->started || manager->reserved < 0 || manager->prepared != manager->reserved) FAIL(INVALID_STATE);
  for (auto p = manager->services; p; p = p->next) {
    int result = bt_gatt_service_register(&p->definition);
    if (result) {
      // A partially published database is not allowed to advertise. Roll back
      // every service registered by this attempt, retaining its native memory.
      for (auto prior = manager->services; prior != p; prior = prior->next) {
        int cleanup = bt_gatt_service_unregister(&prior->definition);
        if (cleanup) controller_broken = true;
        else prior->registered = false;
      }
      return Primitive::os_error(-result, process);
    }
    p->registered = true;
  }
  manager->started = true;
  return process->null_object();
}
PRIMITIVE(set_value) {
  ARGS(BleReadWriteElement, resource, Object, value);
  BleZephyrValue copy;
  bool present;
  Object* error = local_value(process, value, &copy, &present);
  if (error) return error;
  CallbackLock lock;
  resource->data->value = copy;
  resource->data->has_value = present;
  return process->null_object();
}
PRIMITIVE(get_subscribed_clients) {
  ARGS(BleCharacteristicResource, characteristic);
  CallbackLock lock;
  auto data = characteristic->data;
  if (!(data->properties & (BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE))) FAIL(INVALID_ARGUMENT);
  if (!data->deployed || !data->service->registered) {
    Array* empty = process->object_heap()->allocate_array(0, process->null_object());
    if (!empty) FAIL(ALLOCATION_FAILED);
    return empty;
  }
  unsigned tokens[CONFIG_BT_MAX_CONN];
  unsigned count = 0;
  // CCC updates do not take our mutex. This bounded, nonblocking inspection
  // must not be preempted by Zephyr's RX thread on this single-core port.
  k_sched_lock();
  for (const auto& peer : data->service->manager->peers) {
    if (peer.connection && bt_gatt_is_subscribed(peer.connection, data->deployed, BT_GATT_CCC_NOTIFY | BT_GATT_CCC_INDICATE)) {
      tokens[count++] = peer.token;
    }
  }
  k_sched_unlock();
  Array* result = process->object_heap()->allocate_array(count, process->null_object());
  if (!result) FAIL(ALLOCATION_FAILED);
  for (unsigned i = 0; i < count; ++i) result->at_put(i, Smi::from(tokens[i]));
  return result;
}
static unsigned pending_indications = 0;
struct BleLocalIndication {
  bt_gatt_indicate_params params = {};
  // Zephyr retains the parameters through confirmation/disconnect, so its
  // per-send permission attribute must live as long as the copied payload.
  bt_gatt_attr attribute = {};
  BleZephyrValue value;
  bt_conn* connection;
  unsigned references = 2;  // Initiating primitive and Zephyr's destroy callback.
  explicit BleLocalIndication(bt_conn* connection) : connection(bt_conn_ref(connection)) { ++pending_indications; }
  ~BleLocalIndication() { bt_conn_unref(connection); --pending_indications; }
  void release() { if (--references == 0) delete this; }
  static void destroyed(bt_gatt_indicate_params* params) {
    auto self = CONTAINER_OF(params, BleLocalIndication, params);
    CallbackLock lock;
    self->release();
  }
};
PRIMITIVE(notify_characteristics_value) {
  ARGS(BleCharacteristicResource, characteristic, int, token, Object, value);
  auto data = characteristic->data;
  if (!(data->properties & (BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE))) FAIL(INVALID_ARGUMENT);
  BleZephyrValue copy;
  bool present;
  Object* error = local_value(process, value, &copy, &present);
  if (error) return error;
  bt_conn* connection = null;
  bool indication = false;
  BleLocalIndication* operation = null;
  bt_gatt_attr attribute = {};
  {
    CallbackLock lock;
    if (controller_broken || !data->deployed || !data->service->registered) FAIL(INVALID_STATE);
    for (const auto& peer : data->service->manager->peers) {
      if (peer.connection && token > 0 && peer.token == static_cast<unsigned>(token)) { connection = peer.connection; break; }
    }
    // The client can disconnect between enumerating subscribers and sending.
    if (!connection) return process->null_object();
    k_sched_lock();
    bool notify = bt_gatt_is_subscribed(connection, data->deployed, BT_GATT_CCC_NOTIFY);
    indication = !notify && bt_gatt_is_subscribed(connection, data->deployed, BT_GATT_CCC_INDICATE);
    k_sched_unlock();
    if (!notify && !indication) return process->null_object();
    attribute = data->notification_attribute(indication);
    unsigned mtu = bt_gatt_get_mtu(connection);
    if (mtu < 3 || copy.length > mtu - 3) FAIL(OUT_OF_RANGE);
    if (indication) {
      if (pending_indications >= 8) FAIL(QUOTA_EXCEEDED);
      operation = _new BleLocalIndication(connection);
      if (!operation) FAIL(QUOTA_EXCEEDED);
      operation->value = copy;
      operation->attribute = attribute;
      operation->params.attr = &operation->attribute;
      operation->params.data = operation->value.bytes;
      operation->params.len = copy.length;
      operation->params.destroy = BleLocalIndication::destroyed;
    }
    bt_conn_ref(connection);
  }
  // Notifications consume the attribute and copy the payload before returning.
  int result = indication ? bt_gatt_indicate(connection, &operation->params)
      : bt_gatt_notify(connection, &attribute, copy.bytes, copy.length);
  CallbackLock lock;
  bt_conn_unref(connection);
  if (operation) {
    if (result) operation->release();  // No destroy callback for a rejected request.
    operation->release();
  }
  if (result == -ENOMEM || result == -EAGAIN) FAIL(QUOTA_EXCEEDED);
  if (result && result != -ENOTCONN) return Primitive::os_error(-result, process);
  return process->null_object();
}

// Deferred Toit server callbacks and MTU configuration remain.
#define NOT_YET(name) PRIMITIVE(name) { FAIL(UNIMPLEMENTED); }
NOT_YET(advertise_start)
NOT_YET(set_preferred_mtu)
NOT_YET(toit_callback_init)
NOT_YET(toit_callback_deinit)
NOT_YET(toit_callback_reply)
#undef NOT_YET
}  // namespace toit
#endif
