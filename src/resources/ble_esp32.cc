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


namespace toit {

const int kInvalidBLE = -1;

// Only allow one instance of BLE running.
ResourcePool<int, kInvalidBLE> ble_pool(
  0
);

const int kInvalidHandle = UINT16_MAX;

enum {
  kBLEStarted       = 1 << 0,
  kBLECompleted     = 1 << 1,
  kBLEDiscovery     = 1 << 2,
  kBLEConnected     = 1 << 3,
  kBLEConnectFailed = 1 << 4,
};

const uint8 kBluetoothBaseUUID[16] = {
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
  0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB,
};

class BLEDiscovery;

typedef LinkedFIFO<BLEDiscovery> DiscoveriesFIFO;

class BLEDiscovery : public DiscoveriesFIFO::Element {
 public:
  ~BLEDiscovery() {
    free(_data);
  }

  bool init(struct ble_gap_disc_desc& disc) {
    if (disc.length_data > 0) {
      _data = unvoid_cast<uint8*>(malloc(disc.length_data));
      if (!_data) {
        return false;
      }
      memmove(_data, disc.data, disc.length_data);
      _data_length = disc.length_data;
    }

    _addr = disc.addr;
    _rssi = disc.rssi;

    return true;
  }

  ble_addr_t addr() { return _addr; }
  int8_t rssi() { return _rssi; }
  uint8* data() { return _data; }
  uint8_t data_length() { return _data_length; }

 private:
  ble_addr_t _addr;
  int8_t _rssi;
  uint8* _data = null;
  uint8_t _data_length = 0;
};

class BLEResourceGroup : public ResourceGroup {
 public:
  TAG(BLEResourceGroup);
  BLEResourceGroup(Process* process, BLEEventSource* event_source, int id)
      : ResourceGroup(process, event_source)
      , _id(id)
      , _mutex(OS::allocate_mutex(3, "")) {
  }

  void tear_down() override {
    if (is_scanning()) {
      FATAL_IF_NOT_ESP_OK(ble_gap_disc_cancel());
    }

    if (is_advertising()) {
      FATAL_IF_NOT_ESP_OK(ble_gap_adv_stop());
    }

    ResourceGroup::tear_down();
  }

  ~BLEResourceGroup() {
    if (_connection_handle != kInvalidHandle) {
      ble_gap_terminate(_connection_handle, 0);
    }

    nimble_port_deinit();

    FATAL_IF_NOT_ESP_OK(esp_nimble_hci_and_controller_deinit());

    while (remove_next()) {}

    ble_pool.put(_id);
  }

  GAPResource* gap() { return _gap; }
  void set_gap(GAPResource* gap) { _gap = gap; }

  uint32_t on_event(Resource* resource, word data, uint32_t state);

  bool is_advertising() { return _advertising; }
  void set_advertising(bool value) { _advertising = value; }

  bool is_scanning() { return _scanning; }
  void set_scanning(bool value) { _scanning = value; }

  uint16 connection_handle() const {
    Locker locker(_mutex);
    return _connection_handle;
  }

  void clear_connection_handle() {
    Locker locker(_mutex);
    _connection_handle = kInvalidHandle;
  }

  BLEDiscovery* next() {
    Locker locker(_mutex);
    return _discoveries.first();
  }

  bool remove_next() {
    Locker locker(_mutex);
    BLEDiscovery* next = _discoveries.first();
    if (!next) return false;
    _discoveries.remove_first();
    delete next;
    return true;
  }

 private:
  int _id;
  Mutex* _mutex;
  DiscoveriesFIFO _discoveries;
  GAPResource* _gap = null;
  uint16 _connection_handle = kInvalidHandle;
  bool _advertising = false;
  bool _scanning = false;
};

uint32_t BLEResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  struct ble_gap_event* event = reinterpret_cast<struct ble_gap_event*>(data);

  if (event == null) {
    return state | kBLEStarted;
  }

  switch (event->type) {
    case BLE_GAP_EVENT_ADV_COMPLETE:
      state |= kBLECompleted;
      break;

    case BLE_GAP_EVENT_DISC: {
      BLEDiscovery* discovery = _new BLEDiscovery();
      if (!discovery) {
        break;
      }

      if (!discovery->init(event->disc)) {
        delete discovery;
        break;
      }

      {
        Locker locker(_mutex);
        _discoveries.append(discovery);
      }

      state |= kBLEDiscovery;
      break;
    }

    case BLE_GAP_EVENT_DISC_COMPLETE:
      state |= kBLECompleted;
      {
        Locker locker(_mutex);
        set_scanning(false);
      }
      break;

    case BLE_GAP_EVENT_CONNECT: {
      if (event->connect.status == 0) {
        // Success.
        state |= kBLEConnected;
        {
          Locker locker(_mutex);
          ASSERT(_connection_handle == kInvalidHandle);
          _connection_handle = event->connect.conn_handle;
        }
      } else {
        state |= kBLEConnectFailed;
      }
      break;
    }
  }

  return state;
}

static void blecent_on_sync(void) {
    /* Make sure we have proper identity address set (public preferred) */
  int rc = ble_hs_util_ensure_addr(0);
  if (rc != 0) {
    FATAL("error setting address; rc=%d", rc);
  }

  BLEEventSource::on_started();
}

static ble_uuid_any_t uuid_from_blob(Blob blob) {
  ble_uuid_any_t uuid = { 0 };
  if (memcmp(kBluetoothBaseUUID+4, blob.address()+4, 12) == 0) {
    // Check if it's 16 or 32 bytes.
    if (memcmp(kBluetoothBaseUUID, blob.address(), 2) == 0) {
      uuid.u.type = BLE_UUID_TYPE_16;
      uint16 value = *reinterpret_cast<const uint16*>(blob.address() + 2);
      uuid.u16.value = __builtin_bswap16(value);
    } else {
      uuid.u.type = BLE_UUID_TYPE_32;
      uint32 value = *reinterpret_cast<const uint32*>(blob.address());
      uuid.u32.value = __builtin_bswap32(value);
    }
  } else {
    uuid.u.type = BLE_UUID_TYPE_128;
    memcpy_reverse(uuid.u128.value, blob.address(), 16);
  }
  return uuid;
}

MODULE_IMPLEMENTATION(ble, MODULE_BLE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  int id = ble_pool.any();
  if (id == kInvalidBLE) OUT_OF_BOUNDS;

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

  BLEResourceGroup* group = _new BLEResourceGroup(process, ble, id);
  if (!group) {
    ble->unuse();
    ble_pool.put(id);
    MALLOC_FAILED;
  }

  GAPResource* gap = _new GAPResource(group);
  if (!gap) {
    group->tear_down();
    MALLOC_FAILED;
  }

  ble_hs_cfg.sync_cb = blecent_on_sync;

  group->register_resource(gap);
  group->set_gap(gap);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(gap) {
  ARGS(BLEResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  proxy->set_external_address(group->gap());

  return proxy;
}


PRIMITIVE(close) {
  ARGS(BLEResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(scan_start) {
  ARGS(BLEResourceGroup, group, int64, duration_us);

  if (group->is_scanning()) ALREADY_EXISTS;

  int32 duration_ms = duration_us < 0 ? BLE_HS_FOREVER : duration_us / 1000;

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
                     BLEEventSource::on_gap, group->gap());
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  group->set_scanning(true);

  return process->program()->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BLEResourceGroup, group);

  BLEDiscovery* next = group->next();
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
    struct ble_hs_adv_fields fields;
    int rc = ble_hs_adv_parse_fields(&fields, next->data(), next->data_length());
    if (rc == 0) {
      if (fields.name_len > 0) {
        Error* error = null;
        String* name = process->allocate_string((const char*)fields.name, fields.name_len, &error);
        if (error) return error;
        array->at_put(2, name);
      }

      int uuids = fields.num_uuids16 + fields.num_uuids32 + fields.num_uuids128;
      Array* service_classes = process->object_heap()->allocate_array(uuids);
      if (!service_classes) ALLOCATION_FAILED;

      int index = 0;
      for (int i = 0; i < fields.num_uuids16; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(16);
        if (!service_class) ALLOCATION_FAILED;
        ByteArray::Bytes service_class_bytes(service_class);
        memmove(service_class_bytes.address(), kBluetoothBaseUUID, 16);
        *reinterpret_cast<uint32*>(service_class_bytes.address() + 2) = __builtin_bswap16(fields.uuids16[i].value);
        service_classes->at_put(index++, service_class);
      }

      for (int i = 0; i < fields.num_uuids32; i++) {
        ByteArray* service_class = process->object_heap()->allocate_internal_byte_array(16);
        if (!service_class) ALLOCATION_FAILED;
        ByteArray::Bytes service_class_bytes(service_class);
        memmove(service_class_bytes.address(), kBluetoothBaseUUID, 16);
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

  group->remove_next();

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(BLEResourceGroup, group);

  if (group->is_scanning()) {
    int err = ble_gap_disc_cancel();
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
    group->set_scanning(false);
  }

  return process->program()->null_object();
}

PRIMITIVE(advertise_start) {
  ARGS(BLEResourceGroup, group, int64, duration_us, int, interval_us);

  if (group->is_advertising()) ALREADY_EXISTS;

  int32 duration_ms = duration_us < 0 ? BLE_HS_FOREVER : duration_us / 1000;

  struct ble_gap_adv_params adv_params = { 0 };
  // No support for connections yet.
  adv_params.conn_mode = BLE_GAP_CONN_MODE_NON;
  // TODO(anders): Be able to tune this.
  adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
  adv_params.itvl_min = adv_params.itvl_max = interval_us / 625;
  int err = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, null, duration_ms, &adv_params, BLEEventSource::on_gap, group->gap());
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  group->set_advertising(true);

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

  if (group->is_advertising()) {
    int err = ble_gap_adv_stop();
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
    group->set_advertising(false);
  }

  return process->program()->null_object();
}

PRIMITIVE(connect) {
  ARGS(BLEResourceGroup, group, Blob, address);

  uint8_t own_addr_type;

  int err = ble_hs_id_infer_auto(0, &own_addr_type);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  ble_addr_t addr = { 0 };
  addr.type = address.address()[0];
  memmove(addr.val, address.address() + 1, 6);

  err = ble_gap_connect(own_addr_type, &addr, 3000, NULL,
                        BLEEventSource::on_gap, group->gap());
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(get_gatt) {
  ARGS(BLEResourceGroup, group);

  uint16 handle = group->connection_handle();
  if (handle == kInvalidHandle) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  GATTResource* gatt = _new GATTResource(group, handle);
  if (!gatt) MALLOC_FAILED;

  group->register_resource(gatt);
  proxy->set_external_address(gatt);

  group->clear_connection_handle();

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

  const struct os_mbuf* mbuf = gatt->mbuf();
  if (!mbuf) return process->program()->null_object();

  int size = 0;
  for (const os_mbuf* current = mbuf; current; current = SLIST_NEXT(current, om_next)) {
    size += current->om_len;
  }
  ByteArray* data = process->object_heap()->allocate_internal_byte_array(size);
  if (!data) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(data);
  int offset = 0;
  for (const os_mbuf* current = mbuf; current; current = SLIST_NEXT(current, om_next)) {
    memmove(bytes.address() + offset, current->om_data, current->om_len);
    offset += current->om_len;
  }
  gatt->set_mbuf(null);
  return data;
}

PRIMITIVE(request_service) {
  ARGS(GATTResource, gatt, Blob, uuid);

  ble_uuid_any_t ble_uuid = uuid_from_blob(uuid);

  gatt->set_result(UINT32_MAX);

  int err = ble_gattc_disc_svc_by_uuid(
      gatt->handle(), &ble_uuid.u, BLEEventSource::on_gatt_service, gatt);

  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(request_characteristic) {
  ARGS(GATTResource, gatt, uint32, handle_range, Blob, uuid);

  ble_uuid_any_t ble_uuid = uuid_from_blob(uuid);

  gatt->set_result(UINT32_MAX);

  int err = ble_gattc_disc_chrs_by_uuid(
      gatt->handle(), handle_range >> 16, handle_range & 0xffffff,
      &ble_uuid.u, BLEEventSource::on_gatt_characteristic, gatt);

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


} // namespace toit

#endif // TOIT_FREERTOS
