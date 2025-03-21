// Copyright (C) 2022 Toitware ApS.
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

// Note: This is host, we can ignore malloc errors

#include "../top.h"

#include "../objects.h"
#include "../objects_inline.h"
#include "../utils.h"
#include "../event_sources/ble_host.h"

#undef BOOL

#import <CoreBluetooth/CoreBluetooth.h>

@class BleResourceHolder;

namespace toit {

class BleResourceGroup : public ResourceGroup {
 public:
  TAG(BleResourceGroup);

  explicit BleResourceGroup(Process* process)
      : ResourceGroup(process, HostBleEventSource::instance()) {
  }

  void tear_down() override {
    tearing_down_ = true;
    ResourceGroup::tear_down();
  }

  bool is_tearing_down() const { return tearing_down_; }

 protected:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    state |= data;
    return state;
  }

 private:
  bool tearing_down_ = false;
};

class BleCharacteristicResource;
class BleServiceResource;
class BlePeripheralManagerResource;

template <typename T>
class ServiceContainer : public BleResource {
 public:
  ServiceContainer(BleResourceGroup* group, Kind kind)
      : BleResource(group, kind)
      , _service_resource_index([[NSMutableDictionary new] retain]) {}

  ~ServiceContainer() override {
    [_service_resource_index release];
  }

  void delete_or_mark_for_deletion() override;

  virtual T* type() = 0;
  BleServiceResource* get_or_create_service_resource(CBService* service, bool can_create=false);

 private:
  NSMutableDictionary<CBUUID*, BleResourceHolder*>* _service_resource_index;
};

class BleRemoteDeviceResource : public ServiceContainer<BleRemoteDeviceResource> {
 public:
  TAG(BleRemoteDeviceResource);

  BleRemoteDeviceResource(BleResourceGroup* group, CBCentralManager* central_manager, CBPeripheral* peripheral)
      : ServiceContainer(group, REMOTE_DEVICE)
      , _central_manager(central_manager)
      , _peripheral([peripheral retain]) {}

  ~BleRemoteDeviceResource() override {
    [_peripheral release];
  }

  BleRemoteDeviceResource* type() override {
    return this;
  }

  CBPeripheral* peripheral() const { return _peripheral; }
  CBCentralManager* central_manager() const { return _central_manager; }

 private:
  CBCentralManager* _central_manager;
  CBPeripheral* _peripheral;
};

class DiscoverableResource {
 public:
  DiscoverableResource() : _returned(false) {}
  bool is_returned() const { return _returned; }
  void set_returned(bool returned) { _returned = returned; }

 private:
  bool _returned;
};

class BleAdapterResource: public BleResource {
 public:
  TAG(BleAdapterResource);

  BleAdapterResource(BleResourceGroup* group)
      : BleResource(group, ADAPTER) {}
};


// Supports two use cases:
//    - as a service on a remote device (_device is not null)
//    - as a local exposed service (_peripheral_manager is not null)
//      and service can be safely cast to CBMutableService
class BleServiceResource: public BleResource, public DiscoverableResource {
 public:
  TAG(BleServiceResource);

  BleServiceResource(BleResourceGroup* group, BleRemoteDeviceResource* device, CBService* service)
    : BleResource(group, SERVICE)
    , _service([service retain])
    , _device(device)
    , _peripheral_manager(null)
    , _characteristics_resource_index([[NSMutableDictionary new] retain])
    , _deployed(false) {}

  BleServiceResource(BleResourceGroup* group, BlePeripheralManagerResource* peripheral_manager, CBService* service)
      : BleResource(group, SERVICE)
      , _service([service retain])
      , _device(null)
      , _peripheral_manager(peripheral_manager)
      , _characteristics_resource_index([[NSMutableDictionary new] retain])
      , _deployed(false) {}

  ~BleServiceResource() override {
    [_service release];
    [_characteristics_resource_index release];
  }

  void delete_or_mark_for_deletion() override;

  CBService* service() { return _service; }
  BleRemoteDeviceResource* device() { return _device; }
  BlePeripheralManagerResource* peripheral_manager() { return _peripheral_manager; }
  BleCharacteristicResource* get_or_create_characteristic_resource(CBCharacteristic* characteristic, bool can_create= false);
  bool deployed() const { return _deployed; }
  void set_deployed(bool deployed) { _deployed = deployed; }

 private:
  CBService* _service;
  BleRemoteDeviceResource* _device;
  BlePeripheralManagerResource* _peripheral_manager;
  NSMutableDictionary<CBUUID*, BleResourceHolder*>* _characteristics_resource_index;
  bool _deployed;
};

class CharacteristicData;
typedef DoubleLinkedList<CharacteristicData> CharacteristicDataList;
class CharacteristicData: public CharacteristicDataList::Element {
 public:
  explicit CharacteristicData(NSData* data): _data([data retain]) {}
  ~CharacteristicData() { [_data release]; }
  NSData* data() { return _data; }

 private:
  NSData* _data;
};

class BleCharacteristicResource : public BleResource, public DiscoverableResource {
 public:
  TAG(BleCharacteristicResource);

  BleCharacteristicResource(BleResourceGroup* group, BleServiceResource* service, CBCharacteristic* characteristic)
      : BleResource(group, CHARACTERISTIC)
      , _characteristic([characteristic retain])
      , _characteristic_data_list()
      , _service(service)
      , _subscriptions([[NSMutableArray new] retain]) {}

  ~BleCharacteristicResource() override {
    [_characteristic release];
    [_subscriptions release];
  }

  CBCharacteristic* characteristic() { return _characteristic; }

  void set_error(NSError* error) {
    if (_error != nil) [_error release];
    if (error != nil) error = [error retain];
    _error = error;
  }

  NSError* error() {
    return _error;
  }

  void append_data(NSData* data) {
    _characteristic_data_list.append(_new CharacteristicData(data));
  }

  CharacteristicData* remove_first() {
    return _characteristic_data_list.remove_first();
  }

  void put_back(CharacteristicData* data) {
    _characteristic_data_list.prepend(data);
  }

  BleServiceResource* service() { return _service; }

  void add_central(CBCentral* central) {
    [_subscriptions addObject:[central retain]];
  }

  void remove_central(CBCentral* central) {
    [_subscriptions removeObjectIdenticalTo:central];
  }

  int mtu() {
    int min_mtu = 1 << 16; // MTU should maximum be 16 bit.
    for (int i = 0; i < [_subscriptions count]; i++) {
      min_mtu = MIN(min_mtu, _subscriptions[i].maximumUpdateValueLength);
    }
    return min_mtu == 1 << 16 ? 23 : min_mtu; // 23 is the default mtu value in BLE.
  }

 private:
  CBCharacteristic* _characteristic;
  NSError* _error = nil;
  CharacteristicDataList _characteristic_data_list;
  BleServiceResource* _service;
  NSMutableArray<CBCentral*>* _subscriptions;
};

class DiscoveredPeripheral;
typedef DoubleLinkedList<DiscoveredPeripheral> DiscoveredPeripheralList;
class DiscoveredPeripheral : public DiscoveredPeripheralList::Element {
 public:
  DiscoveredPeripheral(CBPeripheral* peripheral, NSNumber* rssi, NSArray* services, NSNumber* connectable,
                                NSData* manufacturerData)
      : _peripheral([peripheral retain]), _rssi([rssi retain]), _services([services retain]),
        _connectable([connectable retain]), _manufacturer_data([manufacturerData retain]) {
  }

  ~DiscoveredPeripheral() {
    [_peripheral release];
    [_rssi release];
    [_services release];
    [_connectable release];
    [_manufacturer_data release];
  }

  CBPeripheral* peripheral() { return _peripheral; }

  NSNumber* rssi() { return _rssi; };

  NSArray* services() const { return _services; }

  NSNumber* connectable() const { return _connectable; }

  NSData* manufacturer_data() const { return _manufacturer_data; }

 private:
  CBPeripheral* _peripheral;
  NSNumber* _rssi;
  NSArray* _services;
  NSNumber* _connectable;
  NSData* _manufacturer_data;
};

class BleCentralManagerResource : public  BleResource {
 public:
  TAG(BleCentralManagerResource);

  explicit BleCentralManagerResource(BleResourceGroup* group)
      : BleResource(group, CENTRAL_MANAGER)
      , _scan_mutex(OS::allocate_mutex(1, "scan"))
      , _stop_scan_condition(OS::allocate_condition_variable(scan_mutex()))
      , _scan_active(false)
      , _central_manager(nil)
      , _newly_discovered_peripherals()
      , _peripherals([[NSMutableDictionary new] retain]) {
  }

  ~BleCentralManagerResource() override {
    if (_central_manager != nil) [_central_manager release];
    [_peripherals release];
    OS::dispose(_stop_scan_condition);
    OS::dispose(_scan_mutex);
  }

  Mutex* scan_mutex() { return _scan_mutex; }

  ConditionVariable* stop_scan_condition() { return _stop_scan_condition; }

  bool scan_active() const { return _scan_active; }

  void set_scan_active(bool scan_active) { _scan_active = scan_active; }

  CBCentralManager* central_manager() { return _central_manager; }
  void set_central_manager(CBCentralManager* central_manager) { _central_manager = [central_manager retain]; }
  void add_discovered_peripheral(DiscoveredPeripheral* discovered_peripheral) {
    if ([_peripherals objectForKey:[discovered_peripheral->peripheral() identifier]] == nil) {
      _peripherals[[discovered_peripheral->peripheral() identifier]] = discovered_peripheral->peripheral();
    }
    // Always add to the list of newly discovered peripherals. They
    // might contain new information if they are a scan response.
    _newly_discovered_peripherals.append(discovered_peripheral);
    HostBleEventSource::instance()->on_event(this, kBleDiscovery);
  }

  DiscoveredPeripheral* next_discovered_peripheral() {
    if (_newly_discovered_peripherals.is_empty()) return null;
    return _newly_discovered_peripherals.remove_first();
  }

  CBPeripheral* get_peripheral(NSUUID* address) {
    return _peripherals[address];
  }

 private:
  Mutex* _scan_mutex;
  ConditionVariable* _stop_scan_condition;
  bool _scan_active;
  CBCentralManager* _central_manager;
  DiscoveredPeripheralList _newly_discovered_peripherals;
  NSMutableDictionary<NSUUID*, CBPeripheral*>* _peripherals;
};

class BlePeripheralManagerResource : public ServiceContainer<BlePeripheralManagerResource> {
 public:
  TAG(BlePeripheralManagerResource);

  explicit BlePeripheralManagerResource(BleResourceGroup* group)
      : ServiceContainer(group, PERIPHERAL_MANAGER)
      , _peripheral_manager(nil)
      , _service_resource_index([[NSMutableDictionary new] retain]) {}

  ~BlePeripheralManagerResource() override {
    if (_peripheral_manager != nil) {
      [_peripheral_manager release];
    }
    [_service_resource_index release];
  }

  CBPeripheralManager* peripheral_manager() const { return _peripheral_manager; }
  void set_peripheral_manager(CBPeripheralManager* peripheral_manager) {
    _peripheral_manager = [peripheral_manager retain];
  }

  BlePeripheralManagerResource* type() override {
    return this;
  }

 private:
  CBPeripheralManager* _peripheral_manager;
  NSMutableDictionary<CBUUID*, BleResourceHolder*>* _service_resource_index;
};

BleCharacteristicResource* lookup_remote_characteristic_resource(CBPeripheral* peripheral, CBCharacteristic* characteristic);
BleCharacteristicResource* lookup_local_characteristic_resource(CBPeripheralManager* peripheral_manager, CBCharacteristic* characteristic);
}

@interface ToitPeripheralDelegate : NSObject <CBPeripheralDelegate>
@property toit::BleRemoteDeviceResource* device;

- (id)initWithDevice:(toit::BleRemoteDeviceResource*)gatt;
@end

@implementation ToitPeripheralDelegate
- (id)initWithDevice:(toit::BleRemoteDeviceResource*)gatt {
  self.device = gatt;
  return self;
}

- (void)peripheral:(CBPeripheral*)peripheral didDiscoverServices:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::BleRemoteDeviceResource* device = ((ToitPeripheralDelegate*) peripheral.delegate).device;
    if (error) {
      // TODO: Record error and return to user code
      toit::HostBleEventSource::instance()->on_event(device, toit::kBleDiscoverOperationFailed);
    } else {
      toit::HostBleEventSource::instance()->on_event(device, toit::kBleServicesDiscovered);
    }
  }
}

- (void)                  peripheral:(CBPeripheral*)peripheral
didDiscoverCharacteristicsForService:(CBService*)service
                               error:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::BleRemoteDeviceResource* device = ((ToitPeripheralDelegate*) peripheral.delegate).device;
    toit::BleServiceResource* service_resource = device->get_or_create_service_resource(service);
    if (service_resource == null) return;
    if (error) {
      // TODO: Record error and return to user code
      toit::HostBleEventSource::instance()->on_event(device, toit::kBleDiscoverOperationFailed);
    } else {
      toit::HostBleEventSource::instance()->on_event(service_resource, toit::kBleCharacteristicsDiscovered);
    }
  }
}

- (void)             peripheral:(CBPeripheral*)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic*)characteristic
                          error:(NSError*)error {
  toit::BleCharacteristicResource* characteristic_resource
      = toit::lookup_remote_characteristic_resource(peripheral, characteristic);
  if (characteristic_resource == null) return;

  if (error != nil) {
    characteristic_resource->set_error(error);
    toit::HostBleEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBleValueDataReadFailed);
  } else {
    characteristic_resource->append_data(characteristic.value);
    toit::HostBleEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBleValueDataReady);
  }
}

- (void)            peripheral:(CBPeripheral*)peripheral
didWriteValueForCharacteristic:(CBCharacteristic*)characteristic
                         error:(NSError*)error {
  toit::BleCharacteristicResource* characteristic_resource
      = toit::lookup_remote_characteristic_resource(peripheral, characteristic);
  if (characteristic_resource == null) return;

  if (error != nil) {
    characteristic_resource->set_error(error);
    toit::HostBleEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBleValueWriteFailed);
  } else {
    toit::HostBleEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBleValueWriteSucceeded);
  }
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral*)peripheral {
  if (peripheral.delegate != nil) {
    toit::BleRemoteDeviceResource* device = ((ToitPeripheralDelegate*) peripheral.delegate).device;
    toit::HostBleEventSource::instance()->on_event(device, toit::kBleReadyToSendWithoutResponse);
  }
}

- (void)                         peripheral:(CBPeripheral*)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic*)characteristic
                                      error:(NSError*)error {
  toit::BleCharacteristicResource* characteristic_resource
      = toit::lookup_remote_characteristic_resource(peripheral, characteristic);
  if (characteristic_resource == null) return;

  if (error != null) {
    characteristic_resource->set_error(error);
    toit::HostBleEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBleSubscriptionOperationFailed);
  } else {
    toit::HostBleEventSource::instance()->on_event(characteristic_resource,
                                                   toit::kBleSubscriptionOperationSucceeded);
  }
}

@end

@interface ToitCentralManagerDelegate : NSObject <CBCentralManagerDelegate>
@property toit::BleCentralManagerResource* central_manager;

- (id)initWithCentralManagerResource:(toit::BleCentralManagerResource*)central_manager;
@end

@implementation ToitCentralManagerDelegate
- (id)initWithCentralManagerResource:(toit::BleCentralManagerResource*)central_manager {
  self.central_manager = central_manager;
  return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager*)central {
  switch (central.state) {
    case CBManagerStateUnknown:
    case CBManagerStateResetting:
    case CBManagerStateUnsupported:
    case CBManagerStateUnauthorized:
    case CBManagerStatePoweredOff:
      break;
    case CBManagerStatePoweredOn:
      toit::HostBleEventSource::instance()->on_event(self.central_manager, toit::kBleStarted);
      break;
  }
}

- (void)centralManager:(CBCentralManager*)central
 didDiscoverPeripheral:(CBPeripheral*)peripheral
     advertisementData:(NSDictionary<NSString*, id>*)advertisementData
                  RSSI:(NSNumber*)rssi {
  auto discovered_peripheral = _new toit::DiscoveredPeripheral(
      peripheral,
      rssi,
      advertisementData[CBAdvertisementDataServiceUUIDsKey],
      advertisementData[CBAdvertisementDataIsConnectable],
      advertisementData[CBAdvertisementDataManufacturerDataKey]);
  self.central_manager->add_discovered_peripheral(discovered_peripheral);
}

- (void)centralManager:(CBCentralManager*)central didConnectPeripheral:(CBPeripheral*)peripheral {
  if (peripheral.delegate != nil) {
    toit::HostBleEventSource::instance()->on_event(((ToitPeripheralDelegate*) peripheral.delegate).device,
                                                   toit::kBleConnected);
  }
}

- (void)centralManager:(CBCentralManager*)central didFailToConnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::HostBleEventSource::instance()->on_event(((ToitPeripheralDelegate*) peripheral.delegate).device,
                                                   toit::kBleConnectFailed);
    [peripheral.delegate release];
    peripheral.delegate = nil;
  }
}

- (void)centralManager:(CBCentralManager*)central didDisconnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error {
  if (peripheral.delegate != nil) {
    toit::HostBleEventSource::instance()->on_event(((ToitPeripheralDelegate*) peripheral.delegate).device,
                                                   toit::kBleDisconnected);
    [peripheral.delegate release];
    peripheral.delegate = nil;
  }
}
@end

@interface ToitPeripheralManagerDelegate : NSObject <CBPeripheralManagerDelegate>
@property toit::BlePeripheralManagerResource* peripheral_manager;
- (id)initWithPeripheralManagerResource:(toit::BlePeripheralManagerResource*)peripheral_manager;
@end

@implementation ToitPeripheralManagerDelegate
- (id)initWithPeripheralManagerResource:(toit::BlePeripheralManagerResource*)peripheral_manager {
  self.peripheral_manager = peripheral_manager;
  return self;
}

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager*)peripheral {
  switch (peripheral.state) {
    case CBManagerStateUnknown:
    case CBManagerStateResetting:
    case CBManagerStateUnsupported:
    case CBManagerStateUnauthorized:
    case CBManagerStatePoweredOff:
      break;
    case CBManagerStatePoweredOn:
      toit::HostBleEventSource::instance()->on_event(self.peripheral_manager, toit::kBleStarted);
      break;
  }
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager*)peripheral error:(NSError*)error {
  if (error) {
    NSLog(@"%@",error);
    toit::HostBleEventSource::instance()->on_event(self.peripheral_manager, toit::kBleAdvertiseStartFailed);
  } else {
    toit::HostBleEventSource::instance()->on_event(self.peripheral_manager, toit::kBleAdvertiseStartSucceeded);
  }
}

- (void)peripheralManager:(CBPeripheralManager*)peripheral didAddService:(CBService*)service error:(NSError*)error {
  toit::BleServiceResource* service_resource = self.peripheral_manager->get_or_create_service_resource(service);
  if (error) {
    NSLog(@"%@",error);
    toit::HostBleEventSource::instance()->on_event(service_resource, toit::kBleServiceAddFailed);
  } else {
    service_resource->set_deployed(true);
    toit::HostBleEventSource::instance()->on_event(service_resource, toit::kBleServiceAddSucceeded);
  }
}

- (void)peripheralManager:(CBPeripheralManager*)peripheral
  didReceiveWriteRequests:(NSArray<CBATTRequest*>*)requests {
  for (int i = 0; i < [requests count]; i++) {
    CBATTRequest* request = requests[i];
    toit::BleCharacteristicResource* characteristic_resource =
        toit::lookup_local_characteristic_resource(peripheral, request.characteristic);

    characteristic_resource->append_data(request.value);
    toit::HostBleEventSource::instance()->on_event(characteristic_resource, toit::kBleDataReceived);
    [peripheral respondToRequest:request withResult:CBATTErrorSuccess];
  }
}

- (void)     peripheralManager:(CBPeripheralManager*)peripheral
                       central:(CBCentral*)central
  didSubscribeToCharacteristic:(CBCharacteristic*)characteristic {
  toit::BleCharacteristicResource* characteristic_resource =
      toit::lookup_local_characteristic_resource(peripheral, characteristic);
  characteristic_resource->add_central(central);
}

- (void)       peripheralManager:(CBPeripheralManager*)peripheral
                         central:(CBCentral*)central
didUnsubscribeFromCharacteristic:(CBCharacteristic*)characteristic {
  toit::BleCharacteristicResource* characteristic_resource =
      toit::lookup_local_characteristic_resource(peripheral, characteristic);
  characteristic_resource->remove_central(central);
}

@end

@interface BleResourceHolder: NSObject
@property toit::BleResource* resource;
- (id)initWithResource:(toit::BleResource*)resource;
@end
@implementation BleResourceHolder
- (id)initWithResource:(toit::BleResource*)resource {
  self.resource = resource;
  return self;
}
@end

namespace toit {

BleCharacteristicResource* lookup_remote_characteristic_resource(CBPeripheral* peripheral, CBCharacteristic* characteristic) {
  if (peripheral.delegate == nil) return null;

  toit::BleRemoteDeviceResource* device = ((ToitPeripheralDelegate*) peripheral.delegate).device;
  toit::BleServiceResource* service = device->get_or_create_service_resource(characteristic.service);
  if (service == null) return null;

  toit::BleCharacteristicResource* characteristic_resource
      = service->get_or_create_characteristic_resource(characteristic);
  return characteristic_resource;
}

BleCharacteristicResource* lookup_local_characteristic_resource(CBPeripheralManager* peripheral_manager, CBCharacteristic* characteristic) {
  if (peripheral_manager.delegate == nil) return null;

  toit::BlePeripheralManagerResource* peripheral_manager_resource = ((ToitPeripheralManagerDelegate*) peripheral_manager.delegate).peripheral_manager;
  toit::BleServiceResource* service = peripheral_manager_resource->get_or_create_service_resource(characteristic.service);
  if (service == null) return null;

  toit::BleCharacteristicResource* characteristic_resource
      = service->get_or_create_characteristic_resource(characteristic);
  return characteristic_resource;
}

template <typename T>
BleServiceResource* ServiceContainer<T>::get_or_create_service_resource(CBService* service, bool can_create) {
  BleResourceHolder* holder = _service_resource_index[[service UUID]];
  if (holder != nil) return static_cast<BleServiceResource*>(holder.resource);
  if (!can_create) return null;

  auto resource = _new BleServiceResource(group(), type(), service);
  resource_group()->register_resource(resource);
  _service_resource_index[[service UUID]] = [[[BleResourceHolder alloc] initWithResource:resource] retain];
  return resource;
}

template<typename T>
void ServiceContainer<T>::delete_or_mark_for_deletion() {
  // Tearing down the resource group will also delete the services (resources) that
	// this service container holds on to. We don't want to do that twice.
  if (!group()->is_tearing_down()) {
    NSArray<BleResourceHolder*>* services = [_service_resource_index allValues];
    for (int i = 0; i < [services count]; i++) {
      group()->unregister_resource(services[i].resource);
    }
  }
  BleResource::delete_or_mark_for_deletion();
}

BleCharacteristicResource* BleServiceResource::get_or_create_characteristic_resource(
    CBCharacteristic* characteristic,
    bool can_create) {
  BleResourceHolder* holder = _characteristics_resource_index[[characteristic UUID]];
  if (holder != nil) return static_cast<BleCharacteristicResource*>(holder.resource);
  if (!can_create) return null;

  auto resource = _new BleCharacteristicResource(group(), this, characteristic);
  resource_group()->register_resource(resource);
  _characteristics_resource_index[[characteristic UUID]] = [[[BleResourceHolder alloc] initWithResource:resource] retain];
  return resource;
}

void BleServiceResource::delete_or_mark_for_deletion() {
  if (!group()->is_tearing_down()) {
    NSArray<BleResourceHolder*>* characteristics = [_characteristics_resource_index allValues];
    for (int i = 0; i < [characteristics count]; i++) {
      group()->unregister_resource(characteristics[i].resource);
    }
  }
  BleResource::delete_or_mark_for_deletion();
}

NSString* ns_string_from_blob(Blob &blob) {
  return [[NSString alloc]
      initWithBytes:blob.address()
             length:blob.length()
           encoding:NSUTF8StringEncoding];
}

CBUUID* cb_uuid_from_blob(Blob &blob) {
  return [CBUUID UUIDWithString:ns_string_from_blob(blob)];
}

NSArray<CBUUID*>* ns_uuid_array_from_array_of_strings(Process* process, Array* array, Error** err) {
  NSMutableArray<CBUUID*>* service_uuids = nil;
  *err = null;
  if (array->length()) {
    service_uuids = [[NSMutableArray alloc] initWithCapacity:array->length()];
    for (int i = 0; i < array->length(); i++) {
      Blob blob;
      Object* obj = array->at(i);
      if (!obj->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) {
        *err = Error::from(process->program()->wrong_object_type());
        return nil;
      }
      service_uuids[i] = cb_uuid_from_blob(blob);
    }
    return service_uuids;
  }
  return nil;
}

MODULE_IMPLEMENTATION(ble, MODULE_BLE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new BleResourceGroup(process);
  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(create_adapter) {
  ARGS(BleResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // On the host we expect '_new' to succeed.
  BleAdapterResource* adapter_resource = _new BleAdapterResource(group);
  group->register_resource(adapter_resource);
  proxy->set_external_address(adapter_resource);

  // On macOS, the adapter is immediately available.
  HostBleEventSource::instance()->on_event(adapter_resource, kBleStarted);

  return proxy;
}

PRIMITIVE(create_central_manager) {
  ARGS(BleAdapterResource, adapter);

  auto group = adapter->group();

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // On the host we expect '_new' to succeed.
  BleCentralManagerResource* central_manager_resource = _new BleCentralManagerResource(group);
  group->register_resource(central_manager_resource);

  auto _centralManagerQueue =
      dispatch_queue_create("toit.centralManagerQueue", DISPATCH_QUEUE_SERIAL);
  ToitCentralManagerDelegate* delegate =
      [[ToitCentralManagerDelegate alloc]
          initWithCentralManagerResource:central_manager_resource];
  CBCentralManager* central_manager =
      [[CBCentralManager alloc]
          initWithDelegate:delegate
                     queue:_centralManagerQueue
                   options:nil];

  central_manager_resource->set_central_manager(central_manager);
  proxy->set_external_address(central_manager_resource);
  return proxy;
}

PRIMITIVE(create_peripheral_manager) {
  ARGS(BleAdapterResource, adapter);

  auto group = adapter->group();

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  BlePeripheralManagerResource* peripheral_manager_resource = _new BlePeripheralManagerResource(group);
  group->register_resource(peripheral_manager_resource);

  auto peripheral_manager_queue =
      dispatch_queue_create("toit.peripheralManagerQueue", DISPATCH_QUEUE_SERIAL);
  ToitPeripheralManagerDelegate* delegate =
      [[ToitPeripheralManagerDelegate alloc]
           initWithPeripheralManagerResource:peripheral_manager_resource];
  CBPeripheralManager* peripheral_manager =
      [[CBPeripheralManager alloc]
          initWithDelegate:delegate
                     queue:peripheral_manager_queue
                   options:nil];

  peripheral_manager_resource->set_peripheral_manager(peripheral_manager);
  proxy->set_external_address(peripheral_manager_resource);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(BleResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(scan_start) {
  ARGS(BleCentralManagerResource, central_manager, bool, passive, int64, duration_us, int, interval, int, window, bool, limited);
  USE(passive);
  USE(interval);
  USE(window);
  USE(limited);
  Locker locker(central_manager->scan_mutex());
  bool active = [central_manager->central_manager() isScanning];

  if (active || central_manager->scan_active()) FAIL(ALREADY_IN_USE);
  central_manager->set_scan_active(true);
  [central_manager->central_manager() scanForPeripheralsWithServices:nil options:nil];

  AsyncThread::run_async([=]() -> void {
    LightLocker locker(central_manager->scan_mutex());
    if (duration_us >= 0) {
      OS::wait_us(central_manager->stop_scan_condition(), duration_us);
    } else {
      OS::wait(central_manager->stop_scan_condition());
    }
    [central_manager->central_manager() stopScan];
    central_manager->set_scan_active(false);
    HostBleEventSource::instance()->on_event(central_manager, kBleCompleted);
  });

  return process->null_object();
}

PRIMITIVE(scan_next) {
  ARGS(BleCentralManagerResource, central_manager);

  DiscoveredPeripheral* peripheral = central_manager->next_discovered_peripheral();
  if (!peripheral) return process->null_object();

  Array* array = process->object_heap()->allocate_array(7, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  const char* address = [[[peripheral->peripheral() identifier] UUIDString] UTF8String];
  String* address_str = process->allocate_string(address);
  if (address_str == null) {
    delete peripheral;
    FAIL(ALLOCATION_FAILED);
  }
  array->at_put(0, address_str);

  array->at_put(1, Smi::from([peripheral->rssi() shortValue]));

  NSString* identifier = [peripheral->peripheral() name];
  if (identifier != nil) {
    String* identifier_str = process->allocate_string([identifier UTF8String]);
    if (identifier_str == null) {
      free(peripheral);
      FAIL(ALLOCATION_FAILED);
    }
    array->at_put(2, identifier_str);
  }

  NSArray* discovered_services = peripheral->services();
  if (discovered_services != nil) {
    Array* service_classes = process->object_heap()->allocate_array(
        static_cast<int>([discovered_services count]),
        process->null_object());

    for (int i = 0; i < [discovered_services count]; i++) {
      String* uuid = process->allocate_string([[discovered_services[i] UUIDString] UTF8String]);
      if (uuid == null) {
        free(peripheral);
        FAIL(ALLOCATION_FAILED);
      }
      service_classes->at_put(i, uuid);
    }
    array->at_put(3, service_classes);
  }

  NSData* manufacturer_data = peripheral->manufacturer_data();
  if (manufacturer_data != nil) {
    ByteArray* custom_data = process->object_heap()->allocate_internal_byte_array(
        static_cast<int>([manufacturer_data length]));
    ByteArray::Bytes custom_data_bytes(custom_data);
    if (!custom_data) FAIL(ALLOCATION_FAILED);
    memcpy(custom_data_bytes.address(), manufacturer_data.bytes, [manufacturer_data length]);

    array->at_put(4, custom_data);
  }

  array->at_put(5, Smi::from(0)); // Flags are not available on Darwin.

  NSNumber* is_connectable = peripheral->connectable();
  Program* program = process->program();
  array->at_put(6, program->boolean(is_connectable != nil && is_connectable.boolValue == YES));

  delete peripheral;

  return array;
}

PRIMITIVE(scan_stop) {
  ARGS(BleCentralManagerResource, central_manager);
  Locker locker(central_manager->scan_mutex());

  if (central_manager->scan_active()) {
    OS::signal(central_manager->stop_scan_condition());
  }

  return process->null_object();
}

PRIMITIVE(connect) {
  ARGS(BleCentralManagerResource, central_manager, Blob, address, bool, secure_connection);
  USE(secure_connection);

  NSUUID* uuid = [[NSUUID alloc] initWithUUIDString:ns_string_from_blob(address)];

  CBPeripheral* peripheral = central_manager->get_peripheral(uuid);
  if (peripheral == nil) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto device =
      _new BleRemoteDeviceResource(
          central_manager->group(),
          central_manager->central_manager(),
          peripheral);

  central_manager->group()->register_resource(device);
  proxy->set_external_address(device);

  peripheral.delegate = [[[ToitPeripheralDelegate alloc] initWithDevice:device] retain];
  [central_manager->central_manager() connectPeripheral:peripheral options:nil];

  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(BleRemoteDeviceResource, device);

  [device->central_manager() cancelPeripheralConnection:device->peripheral()];

  return process->null_object();
}

PRIMITIVE(release_resource) {
  ARGS(Resource, resource);

  resource->resource_group()->unregister_resource(resource);

  return process->null_object();
}

PRIMITIVE(discover_services) {
  ARGS(BleRemoteDeviceResource, device, Array, raw_service_uuids);

  Error* err = null;
  NSArray<CBUUID*>* service_uuids = ns_uuid_array_from_array_of_strings(process, raw_service_uuids, &err);
  if (err) return err;
  [device->peripheral() discoverServices:service_uuids];

  return process->null_object();
}

PRIMITIVE(discover_services_result) {
  ARGS(BleRemoteDeviceResource, device);

  NSArray<CBService*>* services = [device->peripheral() services];
  int count = 0;
  BleServiceResource* service_resources[([services count])];
  for (int i = 0; i < [services count]; i++) {
    BleServiceResource* service_resource = device->get_or_create_service_resource(services[i], true);
    if (service_resource->is_returned()) continue;
    service_resources[count++] = service_resource;
  }

  Array* array = process->object_heap()->allocate_array(count, process->null_object());
  if (array == null) FAIL(ALLOCATION_FAILED);

  for (int i = 0; i < count; i++) {
    BleServiceResource* service_resource = service_resources[i];

    String* uuid_str = process->allocate_string([[services[i].UUID UUIDString] UTF8String]);
    if (uuid_str == null) FAIL(ALLOCATION_FAILED);

    Array* service_info = process->object_heap()->allocate_array(2, process->null_object());
    if (service_info == null) FAIL(ALLOCATION_FAILED);

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) FAIL(ALLOCATION_FAILED);
    proxy->set_external_address(service_resource);

    service_info->at_put(0, uuid_str);
    service_info->at_put(1, proxy);
    array->at_put(i, service_info);
  }

  // Second loop to mark resources as returned, this way there is no need to do clean up on ALLOCATION_FAILED
  for (int i = 0; i < count; i++) service_resources[i]->set_returned(true);

  return array;
}

PRIMITIVE(discover_characteristics) {
  ARGS(BleServiceResource, service, Array, raw_characteristics_uuids);

  if (!service->device()) FAIL(INVALID_ARGUMENT);

  Error* err = null;
  NSArray<CBUUID*>* characteristics_uuids =
      ns_uuid_array_from_array_of_strings(process, raw_characteristics_uuids,&err);
  if (err) return err;

  [service->device()->peripheral() discoverCharacteristics:characteristics_uuids forService:service->service()];

  return process->null_object();
}

PRIMITIVE(discover_characteristics_result) {
  ARGS(BleServiceResource, service);

  NSArray<CBCharacteristic*>* characteristics = [service->service() characteristics];

  int count = 0;
  BleCharacteristicResource* characteristic_resources[([characteristics count])];
  for (int i = 0; i < [characteristics count]; i++) {
    BleCharacteristicResource* characteristic_resource
        = service->get_or_create_characteristic_resource(characteristics[i], true);
    if (characteristic_resource->is_returned()) continue;
    characteristic_resources[count++] = characteristic_resource;
  }

  Array* array = process->object_heap()->allocate_array(count,process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);

  for (int i = 0; i < count; i++) {
    String* uuid_str = process->allocate_string([[characteristics[i].UUID UUIDString] UTF8String]);
    if (uuid_str == null) FAIL(ALLOCATION_FAILED);

    uint16 flags = characteristics[i].properties;

    Array* characteristic_data = process->object_heap()->allocate_array(
        3, process->null_object());
    if (!characteristic_data) FAIL(ALLOCATION_FAILED);

    array->at_put(i, characteristic_data);

    ByteArray* proxy = process->object_heap()->allocate_proxy();
    if (proxy == null) FAIL(ALLOCATION_FAILED);
    proxy->set_external_address(characteristic_resources[i]);

    characteristic_data->at_put(0, uuid_str);
    characteristic_data->at_put(1, Smi::from(flags));
    characteristic_data->at_put(2, proxy);
  }

  // Second loop to mark resources as returned, this way there is no need to do clean up on ALLOCATION_FAILED
  for (int i = 0; i < count; i++) characteristic_resources[i]->set_returned(true);

  return array;
}

PRIMITIVE(discover_descriptors) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(discover_descriptors_result) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(request_read) {
  ARGS(BleCharacteristicResource, characteristic);

  [characteristic->characteristic().service.peripheral readValueForCharacteristic:characteristic->characteristic()];

  return process->null_object();
}

PRIMITIVE(get_value) {
  ARGS(BleCharacteristicResource, characteristic);

  CharacteristicData* data = characteristic->remove_first();
  if (!data) return process->null_object();

  ByteArray* byte_array = process->object_heap()->allocate_internal_byte_array(
      static_cast<int>([data->data() length]));

  if (!byte_array) {
    characteristic->put_back(data);
    FAIL(ALLOCATION_FAILED);
  }

  ByteArray::Bytes bytes(byte_array);
  memcpy(bytes.address(), data->data().bytes, [data->data() length]);
  delete data;

  return byte_array;
}

PRIMITIVE(write_value) {
  ARGS(BleCharacteristicResource, characteristic, Blob, bytes, bool, with_response, bool, allow_retry);

  // TODO(florian): check that the bytes fit into the MTU.
  // TODO(florian): take 'allow_retry' into account.
  USE(allow_retry);

  if (!with_response) {
    if (!characteristic->characteristic().service.peripheral.canSendWriteWithoutResponse)
      return Smi::from(2);
  }

  NSData* data = [[NSData alloc] initWithBytes: bytes.address() length: bytes.length()];
  [characteristic->characteristic().service.peripheral
          writeValue:data
   forCharacteristic:characteristic->characteristic()
                type:(with_response
                   ? CBCharacteristicWriteWithResponse
                   : CBCharacteristicWriteWithoutResponse)];

  return Smi::from(with_response ? 1 : 0);
}

PRIMITIVE(set_characteristic_notify) {
  ARGS(BleCharacteristicResource, characteristic, bool, enable);

  [characteristic->characteristic().service.peripheral
      setNotifyValue:enable
   forCharacteristic:characteristic->characteristic()];

  return process->null_object();
}

PRIMITIVE(advertise_start) {
  ARGS(BlePeripheralManagerResource, peripheral_manager, Blob, name, Array, service_classes,
       int, interval_us, int, conn_mode, int, flags);
  USE(interval_us);
  USE(conn_mode);
  USE(flags);

  NSMutableDictionary* data = [NSMutableDictionary new];

  if (name.length() > 0) {
    data[CBAdvertisementDataLocalNameKey] = ns_string_from_blob(name);
  }

  if (service_classes->length() > 0) {
    Error* err;
    data[CBAdvertisementDataServiceUUIDsKey] = ns_uuid_array_from_array_of_strings(process, service_classes, &err);
    if (err) return err;
  }

  [peripheral_manager->peripheral_manager() startAdvertising:data];

  return process->null_object();
}

PRIMITIVE(advertise_start_raw) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(advertise_stop) {
  ARGS(BlePeripheralManagerResource, peripheral_manager);

  [peripheral_manager->peripheral_manager() stopAdvertising];

  return process->null_object();
}

PRIMITIVE(add_service) {
  ARGS(BlePeripheralManagerResource, peripheral_manager, Blob, uuid);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  CBUUID* cb_uuid = cb_uuid_from_blob(uuid);

  CBMutableService* service = [[CBMutableService alloc] initWithType:cb_uuid primary:TRUE];

  BleServiceResource* service_resource =
    peripheral_manager->get_or_create_service_resource(service, true);

  proxy->set_external_address(service_resource);
  return proxy;
}

PRIMITIVE(add_characteristic) {
  ARGS(BleServiceResource, service_resource, Blob, raw_uuid, int, properties, int, permissions, Object, value);

  if (!service_resource->peripheral_manager()) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (service_resource->deployed()) FAIL(INVALID_ARGUMENT);

  CBUUID* uuid = cb_uuid_from_blob(raw_uuid);

  if (value == process->null_object()) FAIL(UNIMPLEMENTED);

  NSData* data = nil;
  Blob bytes;
  if (!value->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_BYTES_TYPE);
  if (bytes.length()) {
    data = [[NSData alloc] initWithBytes:bytes.address() length:bytes.length()];
  }

  CBMutableCharacteristic* characteristic =
      [[CBMutableCharacteristic alloc]
          initWithType:uuid
            properties:static_cast<CBCharacteristicProperties>(properties)
                 value:data
           permissions:static_cast<CBAttributePermissions>(permissions)];
  auto service = (CBMutableService*)service_resource->service();
  if (service.characteristics)
    service.characteristics = [service.characteristics arrayByAddingObject:characteristic];
  else
    service.characteristics = [NSArray arrayWithObject:characteristic];

  BleCharacteristicResource* characteristic_resource
      = service_resource->get_or_create_characteristic_resource(characteristic, true);
  proxy->set_external_address(characteristic_resource);
  return proxy;
}

PRIMITIVE(add_descriptor) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(handle) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(reserve_services) {
  // Nothing to be done on this platform.
  return process->null_object();
}

PRIMITIVE(deploy_service) {
  ARGS(BleServiceResource, service_resource, int, index);

  if (!service_resource->peripheral_manager()) FAIL(INVALID_ARGUMENT);
  if (service_resource->deployed()) FAIL(INVALID_ARGUMENT);

  auto service = (CBMutableService*)service_resource->service();
  [service_resource->peripheral_manager()->peripheral_manager() addService:service];

  return process->null_object();
}

PRIMITIVE(start_gatt_server) {
  // Nothing to be done on this platform.
  return process->null_object();
}

PRIMITIVE(set_value) {
  ARGS(BleCharacteristicResource, characteristic_resource, Object, value);
  if (value == process->null_object()) FAIL(UNIMPLEMENTED);
  Blob bytes;
  if (!value->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_BYTES_TYPE);

  auto characteristic = (CBMutableCharacteristic*) characteristic_resource->characteristic();
  characteristic.value = [[NSData alloc] initWithBytes:bytes.address() length:bytes.length()];

  return process->null_object();
}

// Just return an array with 1 null object. This will cause the toit code to call notify_characteristics_value with
// a conn_handle of null that we will not use.
PRIMITIVE(get_subscribed_clients) {
  Array* array = process->object_heap()->allocate_array(1, process->null_object());
  if (!array) FAIL(ALLOCATION_FAILED);
  return array;
}

PRIMITIVE(notify_characteristics_value) {
  ARGS(BleCharacteristicResource, characteristic_resource, Object, conn_handle, Object, value);
  USE(conn_handle);

  BlePeripheralManagerResource* peripheral_manager = characteristic_resource->service()->peripheral_manager();
  if (!peripheral_manager) FAIL(WRONG_OBJECT_TYPE);

  Blob bytes;
  if (!value->byte_content(process->program(), &bytes, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_BYTES_TYPE);

  auto characteristic = (CBMutableCharacteristic*) characteristic_resource->characteristic();
  [peripheral_manager->peripheral_manager()
              updateValue:[[NSData alloc] initWithBytes:bytes.address() length:bytes.length()]
        forCharacteristic:characteristic
     onSubscribedCentrals:nil];
  return process->null_object();
}

PRIMITIVE(get_att_mtu) {
  ARGS(BleResource, ble_resource);
  NSUInteger mtu = 23;
  switch (ble_resource->kind()) {
    case BleResource::REMOTE_DEVICE: {
      auto device = static_cast<BleRemoteDeviceResource*>(ble_resource);
      mtu = [device->peripheral() maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse];
      break;
    }
    case BleResource::CHARACTERISTIC: {
      auto characteristic = static_cast<BleCharacteristicResource*>(ble_resource);
      mtu = characteristic->mtu();
      break;
    }
    default:
      break;
  }

  return Smi::from(static_cast<int>(mtu));
}

PRIMITIVE(set_preferred_mtu) {
  ARGS(BleAdapterResource, resource);
  // Ignore
  return process->null_object();
}

PRIMITIVE(get_error) {
  ARGS(BleCharacteristicResource, characteristic, bool, is_oom);
  // Darwin should never have OOM errors.
  if (is_oom) FAIL(ERROR);
  if (characteristic->error() == nil) FAIL(ERROR);
  String* message = process->allocate_string([characteristic->error().localizedDescription UTF8String]);
  if (!message) FAIL(ALLOCATION_FAILED);

  return Primitive::mark_as_error(message);
}

PRIMITIVE(clear_error) {
  ARGS(BleCharacteristicResource, characteristic, bool, is_oom);
  // Darwin should never have OOM errors.
  if (is_oom) FAIL(ERROR);
  if (characteristic->error() == nil) FAIL(ERROR);
  characteristic->set_error(nil);

  return process->null_object();
}

PRIMITIVE(toit_callback_init) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(toit_callback_deinit) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(toit_callback_reply) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(get_bonded_peers) {
  ARGS(BleCentralManagerResource, central_manager);
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(set_gap_device_name) {
  ARGS(BleAdapterResource, adapter, cstring, name)
  USE(name);
  FAIL(UNIMPLEMENTED);
}

}
