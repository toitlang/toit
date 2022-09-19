// Copyright (C) 2018 Toitware ApS.
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

#if  defined(TOIT_LINUX) || defined(TOIT_WINDOWS)

#include "../objects.h"
#include "../objects_inline.h"
#include "../event_sources/ble_host.h"
#include <simpleble/SimpleBLE.h>

#include <utility>

namespace toit {

enum {
  kBLEStarted = 1 << 0,
  kBLECompleted = 1 << 1,
  kBLEDiscovery = 1 << 2,
  kBLEConnected = 1 << 3,
  kBLEConnectFailed = 1 << 4,
  kBLEDisconnected = 1 << 5,
};

// This is to simulate GAP on the host side, to satisfy the toit code.
class GAPResource : public BLEResource {
 public:
  TAG(GAPResource);

  explicit GAPResource(ResourceGroup* group) : BLEResource(group, GAP) {}
};

class GATTResource : public BLEResource {
 public:
  TAG(GAPResource);

  explicit GATTResource(ResourceGroup* group)
      : BLEResource(group, GATT), _peripheral(null) {}

  ~GATTResource() override {
    if (_peripheral) free(_peripheral);
  }

  void set_peripheral(Peripheral* peripheral) { _peripheral = peripheral; }

  [[nodiscard]] Peripheral* peripheral() const { return _peripheral; }

 private:
  Peripheral* _peripheral;
};

class BLEResourceGroup : public ResourceGroup {
 public:
  TAG(BLEResourceGroup);

  BLEResourceGroup(Process* process, Adapter* adapter)
      : ResourceGroup(process, HostBLEEventSource::instance()), _adapter(adapter),
        _scan_mutex(OS::allocate_mutex(1, "scan")), _stop_scan_condition(OS::allocate_condition_variable(scan_mutex())),
        _scan_active(false) {
    _gap_resource = _new GAPResource(this); // This is host, we can ignore malloc errors
    this->register_resource(_gap_resource);

    _simple_ble_adapter_resource = _new SimpleBLEAdapterResource(this,
                                                                 adapter); // This is host, we can ignore malloc errors
    this->register_resource(_simple_ble_adapter_resource);
  }

  GAPResource* gap() { return _gap_resource; }

  SimpleBLEAdapterResource* adapter_resource() { return _simple_ble_adapter_resource; }

  Adapter* adapter() { return _adapter; }

  Mutex* scan_mutex() { return _scan_mutex; }

  ConditionVariable* stop_scan_condition() { return _stop_scan_condition; }

  bool scan_active() const { return _scan_active; }

  void set_scan_active(bool scan_active) { _scan_active = scan_active; }

 protected:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

 private:
  Adapter* _adapter;
  GAPResource* _gap_resource;
  SimpleBLEAdapterResource* _simple_ble_adapter_resource;
  Mutex* _scan_mutex;
  ConditionVariable* _stop_scan_condition;
  bool _scan_active;
};


uint32_t BLEResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  switch (data) {
    case SIMPLEBLE_INIT:
      state |= kBLEStarted;
      break;
    case SIMPLEBLE_SCAN_STOP:
      state |= kBLECompleted;
      break;
    case SIMPLEBLE_SCAN_FOUND:
      state |= kBLEDiscovery;
      break;
    case SIMPLEBLE_CONNECTED_TO_REMOTE:
      state |= kBLEConnected;
      break;
    case SIMPLEBLE_FAILED_CONNECT_TO_REMOTE:
      state |= kBLEConnectFailed;
      break;
    default:
      break;
  }
  return state;
}

MODULE_IMPLEMENTATION(ble, MODULE_BLE)

PRIMITIVE(init) {
  ARGS(word, device);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (!Adapter::bluetooth_enabled()) HARDWARE_ERROR;

  std::vector<Adapter> adapters = Adapter::get_adapters().value_or(std::vector<Adapter>());

  if (adapters.empty()) HARDWARE_ERROR;

  if (device >= adapters.size()) OUT_OF_RANGE;

  proxy->set_external_address(_new BLEResourceGroup(process, new Adapter(adapters[device])));
  return proxy;
}


PRIMITIVE(gap) {
  ARGS(BLEResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  proxy->set_external_address(group->adapter_resource());

  return proxy;
}

PRIMITIVE(close) {
  ARGS(BLEResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

class AsyncThread : public Thread {
 public:
  explicit AsyncThread(std::function<void()> func) : Thread("async"), _func(std::move(func)) {
    spawn();
  }

 protected:
  void entry() override {
    _func();
    delete this;
  }

 private:
  const std::function<void()> _func;
};

static void run_async(const std::function<void()> &func) {
  _new AsyncThread(func);
}

PRIMITIVE(scan_start) {
  ARGS(BLEResourceGroup, group, int64, duration_us);
  Locker locker(group->scan_mutex());
  bool active = group->adapter()->scan_is_active().value_or(false);

  if (active || group->scan_active()) ALREADY_IN_USE;
  group->set_scan_active(true);
  group->adapter()->scan_start();
  run_async([=]() -> void {
    LightLocker locker(group->scan_mutex());
    OS::wait_us(group->stop_scan_condition(), duration_us);
    group->adapter()->scan_stop();
    group->set_scan_active(false);
  });
  return process->program()->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BLEResourceGroup, group);

  Peripheral* peripheral = group->adapter_resource()->next_peripheral();
  if (!peripheral) return process->program()->null_object();

  Array* array = process->object_heap()->allocate_array(6, process->program()->null_object());
  if (!array) ALLOCATION_FAILED;

  if (!peripheral->address().has_value()) {
    delete peripheral;
    INVALID_ARGUMENT;
  }

  Error* err = null;
  String* address_str = process->allocate_string(peripheral->address().value().c_str(), &err);
  if (address_str == null) {
    delete peripheral;
    return err;
  }
  array->at_put(0, address_str);

  array->at_put(1, Smi::from(peripheral->rssi().value_or(INT16_MIN)));

  String* identifier_str = process->allocate_string(peripheral->identifier().value_or("").c_str(), &err);
  if (identifier_str == null) {
    free(peripheral);
    return err;
  }
  array->at_put(2, identifier_str);

  std::list<std::string> services = peripheral->discovered_services().value_or(std::list<std::string>());

  Array* service_classes = process->object_heap()->allocate_array(static_cast<int>(services.size()),
                                                                  process->program()->null_object());
  if (!service_classes) {
    free(peripheral);
    ALLOCATION_FAILED;
  }
  int idx = 0;
  for (const auto &item: peripheral->discovered_services().value_or(std::list<std::string>())) {
    String* uuid = process->allocate_string(item.c_str(), &err);
    if (uuid == null) {
      free(peripheral);
      return err;
    }

    service_classes->at_put(idx++, uuid);
  }
  array->at_put(3, service_classes);

  std::map<uint16_t, SimpleBLE::ByteArray> manufacturer_map = peripheral->manufacturer_data().value_or(
      std::map<uint16_t, SimpleBLE::ByteArray>());
  if (!manufacturer_map.empty()) {
    auto &selected_manufacturer_data = *(manufacturer_map.begin());
    uint16_t manufacturer_id = selected_manufacturer_data.first;
    SimpleBLE::ByteArray data = selected_manufacturer_data.second;

    ByteArray* custom_data = process->object_heap()->allocate_internal_byte_array(static_cast<int>(data.size() + 2));
    if (!custom_data) ALLOCATION_FAILED;
    ByteArray::Bytes custom_data_bytes(custom_data);
    memcpy(custom_data_bytes.address() + 2, data.data(), data.size());
    memcpy(custom_data_bytes.address(), (uint8_t[]) {
        static_cast<uint8_t>(manufacturer_id & 0xFF),
        static_cast<uint8_t>((manufacturer_id >> 8) & 0xFF)}, 2);
    array->at_put(4, custom_data);
  }

  bool connectable = peripheral->is_connectable().value_or(false);
  array->at_put(5, BOOL(connectable));

  free(peripheral);

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(BLEResourceGroup, group);
  Locker locker(group->scan_mutex());
  if (group->scan_active()) {
    OS::signal(group->stop_scan_condition());
  }
  return process->program()->null_object();
}

PRIMITIVE(advertise_start) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(advertise_config) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(advertise_stop) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(connect) {
  ARGS(BLEResourceGroup, group, Blob, address, GATTResource, gatt);

  for (auto &peripheral: group->adapter()->scan_get_results().value_or(std::vector<Peripheral>())) {
    if (peripheral.address().has_value() &&
        !memcmp(peripheral.address().value().c_str(), address.address(), address.length())) {
      auto* heap_peripheral = new Peripheral(peripheral);
      run_async([=]() {
        bool success = heap_peripheral->connect();
        ((HostBLEEventSource*) group->event_source())->on_connection(gatt, success);
        if (success) {
          gatt->set_peripheral(heap_peripheral);
          auto services = heap_peripheral->services();


          if (services.has_value()) {
            for (int i = 0; i < services.value().size(); i++) {
              SimpleBLE::Service service = services.value()[i];
              printf("Service: %s\n", service.uuid().c_str());
              for (auto characteristic: service.characteristics()) {
                printf("   Char: %s\n", characteristic.uuid().c_str());
                for (auto descriptor: characteristic.descriptors()) {
                  printf("     Desc: %s\n", descriptor.uuid().c_str());

                }
              }
            }
          }
        } else {
          delete heap_peripheral;
        }
      });
      return process->program()->null_object();
    }
  }

  INVALID_ARGUMENT;
}

PRIMITIVE(get_gatt) {
  ARGS(BLEResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;

  auto gatt = _new GATTResource(group);

  group->register_resource(gatt);
  proxy->set_external_address(gatt);

  return proxy;
}

PRIMITIVE(list_services) {
  ARGS(GATTResource, gatt);

  if(!gatt->peripheral()) INVALID_ARGUMENT;
  auto services = gatt->peripheral()->services();
  if (services.has_value()) {
    Array* services_array = process->object_heap()->allocate_array(
        static_cast<int>(services.value().size()),
        process->program()->null_object());
    if (!services_array) ALLOCATION_FAILED;
    Error *err = null;
    for (int i = 0; i < services.value().size(); i++) {
      Array* service_array = process->object_heap()->allocate_array(2, process->program()->null_object());
      if (!service_array) ALLOCATION_FAILED;
      services_array->at_put(i, service_array);
      SimpleBLE::Service service = services.value()[i];

      String* service_uuid = process->allocate_string(service.uuid().c_str(), &err);
      if (service_uuid == null) return err;
      service_array->at_put(0, service_uuid);

      Array* characteristics_array = process->object_heap()->allocate_array(
          static_cast<int>(service.characteristics().size()),
          process->program()->null_object());
      service_array->at_put(1, characteristics_array);
      for (int j = 0; j < service.characteristics().size(); j++) {
        Array* characteristic_array = process->object_heap()->allocate_array(2,
                                                                             process->program()->null_object());
        characteristics_array->at_put(j, characteristic_array);
        auto characteristic = service.characteristics()[j];
        String* characteristic_uuid = process->allocate_string(characteristic.uuid().c_str(), &err);
        if (characteristic_uuid == null) return err;
        characteristic_array->at_put(0, characteristic_uuid);

        Array* descriptors_array = process->object_heap()->allocate_array(
            static_cast<int>(characteristic.descriptors().size()),
            process->program()->null_object());
        characteristic_array->at_put(1, descriptors_array);
        for (int k = 0; k < characteristic.descriptors().size(); k++) {
          auto descriptor = characteristic.descriptors()[k];
          String* descriptor_uuid = process->allocate_string(descriptor.uuid().c_str(), &err);
          if (descriptor_uuid == null) return err;
          descriptors_array->at_put(k, descriptor_uuid);
        }
      }
    }
    return services_array;
  }

  return process->program()->null_object();
}

PRIMITIVE(request_result) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(request_data) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(send_data) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(request_service) {
  ARGS(GATTResource, gatt, Blob, uuid);
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(request_characteristic) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(request_attribute) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(server_configuration_init) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(server_configuration_dispose) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(add_server_service) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(add_server_characteristic) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(set_characteristics_value) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(notify_characteristics_value) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(get_characteristics_value) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(get_att_mtu) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(set_preferred_mtu) {
  // Ignore
  return process->program()->null_object();
}

}
#endif