// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
import monitor
import uuid
import bytes
import monitor show ResourceState_
import encoding.hex
import device

class BleUUID:
  data_/any
  constructor .data_:
    if data_ is ByteArray:
      if data_.size !=2 and data_.size != 4 and data_.size != 16: throw "INVALID UUID"
    else if data_ is string:
      if data_.size != 4 and data_.size != 8 and data_.size != 36: throw "INVALID UUID"
      if data_.size == 36:
        uuid.parse data_ // This throws an exception if the format is incorrect
      else:
        if (catch: hex.decode data_):
          throw "INVALID UUID"
      data_ = data_.to_ascii_lower

  stringify -> string:
    if data_ is ByteArray:
      if data_.size <= 4:
        return hex.encode data_
      else:
        return (uuid.Uuid data_).stringify
    else:
      return data_

  to_byte_array:
    if data_ is string:
      if data_.size <= 4: return hex.decode data_
      return (uuid.parse data_).to_byte_array
    else:
      return data_

  encode_for_platform_:
    if ble_platform_requires_uuid_as_byte_array_:
      return to_byte_array
    else:
      return stringify

  hash_code:
    return data_.hash_code

  operator== other/BleUUID: return data_ == other.data_

interface Attribute:
  uuid -> BleUUID

BLE_CONNECT_MODE_NONE          ::= 0
BLE_CONNECT_MODE_DIRECTIONAL   ::= 1
BLE_CONNECT_MODE_UNDIRECTIONAL ::= 2

BLE_DEFAULT_PREFERRED_MTU_     ::= 23

/**
Advertisement data as either sent by advertising or received through scanning.
*/
class AdvertisementData:
  /**
  The advertised name of the device.
  */
  name/string?

  /**
  Advertised service classes as a list of uuid.
  */
  service_classes/List

  /**
  Advertised manufacturer-specific data.
  */
  manufacturer_data/ByteArray

  /**
  Allows connections
  */
  connectable/bool

  constructor --.name=null --.service_classes=[] --.manufacturer_data=#[] --.connectable=false:

/**
A remote device discovered by a scanning.
*/
class RemoteScannedDevice:
  /**
  The BLE address of the remote device.
  */
  address/any

  /**
  The RSSI measured for the remote device.
  */
  rssi/int

  /**
  The advertisement data received from the remote device.
  */
  data/AdvertisementData
  /**
  Constructs a remote device with the given $address, $rssi, and $data.
  */
  constructor .address .rssi .data:

  /**
  See $super.
  */
  stringify -> string:
    return "$address (rssi: $rssi dBm)"

CHARACTERISTIC_PROPERTY_BROADCAST                    ::= 0x001
CHARACTERISTIC_PROPERTY_READ                         ::= 0x002
CHARACTERISTIC_PROPERTY_WRITE_WITHOUT_RESPONSE       ::= 0x004
CHARACTERISTIC_PROPERTY_WRITE                        ::= 0x008
CHARACTERISTIC_PROPERTY_NOTIFY                       ::= 0x010
CHARACTERISTIC_PROPERTY_INDICATE                     ::= 0x020
CHARACTERISTIC_PROPERTY_AUTHENTICATED_SIGNED_WRITES  ::= 0x040
CHARACTERISTIC_PROPERTY_EXTENDED_PROPERTIES          ::= 0x080
CHARACTERISTIC_PROPERTY_NOTIFY_ENCRYPTION_REQUIRED   ::= 0x100
CHARACTERISTIC_PROPERTY_INDICATE_ENCRYPTION_REQUIRED ::= 0x200

CHARACTERISTIC_PERMISSION_READ                       ::= 0x01
CHARACTERISTIC_PERMISSION_WRITE                      ::= 0x02
CHARACTERISTIC_PERMISSION_READ_ENCRYPTED             ::= 0x04
CHARACTERISTIC_PERMISSION_WRITE_ENCRYPTED            ::= 0x08

/**
A remote characteristic belonging to a remote service.
*/
class RemoteCharacteristic extends Resource_ implements Attribute:
  service/RemoteService
  uuid/BleUUID
  properties/int

  characteristic_/any
  /**
  Constructs remote characteristic from the given $service, $handle, and $definition_handle.
  */
  constructor .service/RemoteService .uuid .properties .characteristic_:
    super service.device.manager.adapter.resource_group_ characteristic_

  /**
  Reads the value of the characteristic on the remote service.

  Returns `null` if the characteristic is invalid or empty.
  */
  value -> ByteArray?:
    if (properties & (CHARACTERISTIC_PROPERTY_READ
                      | CHARACTERISTIC_PROPERTY_INDICATE
                      | CHARACTERISTIC_PROPERTY_NOTIFY)) == 0:
      throw "Characteristic does not support reads"

    if properties & CHARACTERISTIC_PROPERTY_READ != 0:
      resource_state_.clear_state VALUE_DATA_READY_EVENT_
      ble_request_characteristic_read_ characteristic_
      state := resource_state_.wait_for_state VALUE_DATA_READY_EVENT_ | VALUE_DATA_READ_FAILED_EVENT_
      if state & VALUE_DATA_READ_FAILED_EVENT_ != 0: throw_error_
      return ble_get_characteristic_value_ characteristic_
    else:
      while true:
        buf := ble_get_characteristic_value_ characteristic_
        if buf: return buf
        resource_state_.clear_state VALUE_DATA_READY_EVENT_
        state := resource_state_.wait_for_state VALUE_DATA_READY_EVENT_ | VALUE_DATA_READ_FAILED_EVENT_
        if state & VALUE_DATA_READ_FAILED_EVENT_ != 0: throw_error_

  /**
  Writes the value of the characteristic on the remote service.
  */
  value= value/ByteArray -> none:
    if (properties & (CHARACTERISTIC_PROPERTY_WRITE
                      | CHARACTERISTIC_PROPERTY_WRITE_WITHOUT_RESPONSE)) == 0:
      throw "Characteristic does not support write"

    while true:
      service.device.resource_state_.clear_state READY_TO_SEND_WITHOUT_RESPONSE_EVENT_
      with_response := (properties & CHARACTERISTIC_PROPERTY_WRITE) != 0
                       ? true
                       : false
      result :=
        ble_write_characteristic_value_
            characteristic_
            value
            with_response
      if result == 0: return // Write without response success
      if result == 1: // Write with response
        state := resource_state_.wait_for_state VALUE_WRITE_FAILED_EVENT_ | VALUE_WRITE_SUCCEEDED_EVENT_
        if (state & VALUE_WRITE_FAILED_EVENT_) != 0: throw_error_
        return
      if result == 2: // Write without response, needs to wait for device ready
        service.device.resource_state_.wait_for_state READY_TO_SEND_WITHOUT_RESPONSE_EVENT_

  notify= value/bool -> none:
    if (properties & (CHARACTERISTIC_PROPERTY_INDICATE
                    | CHARACTERISTIC_PROPERTY_NOTIFY)) == 0:
      throw "Characteristic does not support notification or indication"
    resource_state_.clear_state  SUBSCRIPTION_OPERATION_FAILED_
    ble_set_characteristic_notify_ characteristic_ value
    state := resource_state_.wait_for_state SUBSCRIPTION_OPERATION_SUCCEEDED_ | SUBSCRIPTION_OPERATION_FAILED_
    if (state & SUBSCRIPTION_OPERATION_FAILED_) != 0:
      throw_error_

  throw_error_:
    throw
      ble_get_characteristic_error_ characteristic_

/**
A remote service connected to a remote device through a client.
*/
class RemoteService extends Resource_ implements Attribute:
  /** The ID of the remote service. */
  uuid/BleUUID

  device/RemoteConnectedDevice

  service_/any
  /**
  Constructs a remote service from the given $client_, $service_id, and $handle_range_.
  */
  constructor .device .uuid .service_:
    super device.manager.adapter.resource_group_ service_

  discover_characteristics characteristic_uuids/List=[] -> List:
    resource_state_.clear_state CHARACTERISTIS_DISCOVERED_EVENT_
    raw_service_uuids := characteristic_uuids.map: | uuid/BleUUID | uuid.encode_for_platform_
    ble_discover_characteristics_ service_ (Array_.ensure raw_service_uuids)
    state := resource_state_.wait_for_state CHARACTERISTIS_DISCOVERED_EVENT_ | DISCONNECTED_EVENT_
    if state & DISCONNECTED_EVENT_ != 0:
      throw "BLE disconnected"
    return
      order_attributes_
          characteristic_uuids
          List.from
            (ble_discover_characteristics_result_ service_).map:
              RemoteCharacteristic this (BleUUID it[0]) it[1] it[2]


  /**
  Reads a remote characteristic on the remote service by looking up the handle of the given $characteristic_uuid.

  # Advanced
  Every call to $read_characteristic downloads the characteristic from the remote device.
    It is therefore recommended to cache and reuse the value rather than calling $read_characteristic multiple times.
  */
//  read_characteristic characteristic_uuid/BleUUID -> RemoteCharacteristic:
////    ble_request_characteristic_ client_.gatt_ handle_range_ characteristic_uuid.encode_for_host_
//    client_.wait_for_done_
//    result := ble_request_result_ client_.gatt_
//    return RemoteCharacteristic
//      this
//      result >> 16
//      --definition_handle=result & 0xFFFF

  /**
  Reads the value of the characteristic with the given $characteristic_uuid.

  This is a convenience method that first does a characteristic lookup and then reads the value.
  */
//  read_value characteristic_uuid/BleUUID -> ByteArray?:
//    characteristic := read_characteristic characteristic_uuid
//    return characteristic.read_value


/**
A remote connected device.
*/
class RemoteConnectedDevice extends Resource_:
  manager/CentralManager
  /**
  The address of the remote device the client is connected to.
  */
  address/any

  device_/any

  constructor .manager .address:
    device_ = ble_connect_ manager.resource_ address
    super manager.adapter.resource_group_ device_
    state := resource_state_.wait_for_state CONNECTED_EVENT_ | CONNECT_FAILED_EVENT_
    if state & CONNECT_FAILED_EVENT_ != 0:
      close_
      throw "BLE connection failed"
      // TODO Possible leak of the gatt_ resource on connection failures

  /**
  Reads a remote service by looking up the given $service_uuid on the remote device.
  */
  discover_services service_uuids/List=[] -> List:
    resource_state_.clear_state SERVICES_DISCOVERED_EVENT_
    raw_service_uuids := service_uuids.map: | uuid/BleUUID | uuid.encode_for_platform_
    ble_discover_services_ device_ (Array_.ensure raw_service_uuids)
    state := resource_state_.wait_for_state SERVICES_DISCOVERED_EVENT_ | DISCONNECTED_EVENT_
    if state & DISCONNECTED_EVENT_ != 0:
      throw "BLE disconnected"
    return
      order_attributes_
          service_uuids
          List.from
              (ble_discover_services_result_ device_).map:
                RemoteService this (BleUUID it[0]) it[1]

  disconnect:
    ble_disconnect_ device_
    resource_state_.wait_for_state DISCONNECTED_EVENT_
    close_


/**
Defines a BLE service with characteristics.
*/
class LocalService extends Resource_ implements Attribute:
  /**
  The UUID of the service.

  For 16 and 32 bit UUIDs, form the BLE variant with the top-level uuid function.
  */
  uuid/BleUUID
  peripheral_manager/PeripheralManager

  constructor .peripheral_manager .uuid:
    resource := ble_add_service_ peripheral_manager.resource_ uuid.encode_for_platform_
    super peripheral_manager.adapter.resource_group_ resource

  add_characteristic
      uuid/BleUUID
      --properties/int
      --permissions/int
      --value/ByteArray=#[] -> LocalCharacteristic:
    return LocalCharacteristic this uuid properties permissions value


  add_read_only_characteristic uuid/BleUUID --value/ByteArray -> LocalCharacteristic:
    return add_characteristic
        uuid
        --properties=CHARACTERISTIC_PROPERTY_READ
        --permissions=CHARACTERISTIC_PERMISSION_READ
        --value=value

  add_write_only_characteristic uuid/BleUUID requires_response/bool=false -> LocalCharacteristic:
    return add_characteristic
        uuid
        --properties=requires_response?CHARACTERISTIC_PROPERTY_WRITE:CHARACTERISTIC_PROPERTY_WRITE
        --permissions=CHARACTERISTIC_PERMISSION_WRITE

  add_notification_characteristuc uuid/BleUUID indication/bool=false -> LocalCharacteristic:
    return add_characteristic
        uuid
        --properties=indication?CHARACTERISTIC_PROPERTY_INDICATE:CHARACTERISTIC_PROPERTY_NOTIFY
        --permissions=CHARACTERISTIC_PERMISSION_READ

  deploy:
    ble_deploy_service_ resource_
    state := resource_state_.wait_for_state SERVICE_ADD_SUCCEEDED_EVENT_ | SERVICE_ADD_FAILED_EVENT_
    if state & SERVICE_ADD_FAILED_EVENT_ != 0: throw "Failed to add service"

class LocalCharacteristic extends Resource_ implements Attribute:
  uuid/BleUUID

  permissions/int
  properties/int
  service/LocalService

  constructor .service .uuid .properties .permissions value/ByteArray:
    resource := ble_add_service_characteristic_ service.resource_ uuid.encode_for_platform_ properties permissions value
    super service.peripheral_manager.adapter.resource_group_ resource

  value= value/ByteArray:
    if permissions & CHARACTERISTIC_PERMISSION_READ == 0: throw "Invalid permission"

    if (properties & (CHARACTERISTIC_PROPERTY_NOTIFY | CHARACTERISTIC_PROPERTY_INDICATE)) != 0:
      ble_notify_characteristics_value_ resource_ value
    else:
      ble_set_characteristics_value_ resource_ value

  value -> ByteArray:
    if (permissions & CHARACTERISTIC_PERMISSION_WRITE) == 0:
      throw "Invalid permission"

    resource_state_.clear_state DATA_RECEIVED_EVENT_
    while true:
      buf := ble_get_characteristic_value_ resource_
      if buf: return buf
      resource_state_.wait_for_state DATA_RECEIVED_EVENT_


/**
The manager for creating client connections.
*/
class CentralManager extends Resource_:
  adapter/Adapter

  constructor .adapter:
    resource := ble_create_central_manager_ adapter.resource_group_
    super adapter.resource_group_ resource
    resource_state_.wait_for_state STARTED_EVENT_

  /**
  Connects to the remote device with the given $address.

  Connections cannot be established while a scan is ongoing.
  */
  connect address/any -> RemoteConnectedDevice:
    return RemoteConnectedDevice this address


  /**
  Scans for nearby devices. This method blocks while the scan is ongoing.

  Only one scan can run at a time.

  Connections cannot be established while a scan is ongoing.

  Stops the scan after the given $duration.
  */
  scan [block] --duration/Duration?=null:
    duration_us := duration ? (max 0 duration.in_us) : -1
    resource_state_.clear_state COMPLETED_EVENT_
    ble_scan_start_ resource_ duration_us
    try:
      while true:
        state := resource_state_.wait_for_state DISCOVERY_EVENT_ | COMPLETED_EVENT_
        next := ble_scan_next_ resource_
        if not next:
          resource_state_.clear_state DISCOVERY_EVENT_
          if state & COMPLETED_EVENT_ != 0: return
          continue
        service_classes := []
        raw_service_classes := next[3]
        if raw_service_classes:
          raw_service_classes.size.repeat:
            service_classes.add
                BleUUID raw_service_classes[it]

        discovery := RemoteScannedDevice
          next[0]
          next[1]
          AdvertisementData
            --name=next[2]
            --service_classes=service_classes
            --manufacturer_data=next[4]
            --connectable=next[5]
        block.call discovery
    finally:
      ble_scan_stop_ resource_
      resource_state_.wait_for_state COMPLETED_EVENT_

/**
The manager for advertising and managing local services.
*/

class PeripheralManager extends Resource_:
  static DEFAULT_INTERVAL ::= Duration --us=46875
  adapter/Adapter

  constructor .adapter:
    resource := ble_create_peripheral_manager_ adapter.resource_group_
    super adapter.resource_group_ resource
    resource_state_.wait_for_state STARTED_EVENT_

  /**
  Starts advertising the $data.

  The data is advertised once every $interval.

  The advertise will include the given $connection_mode, use one
    of the BLE_CONNECTION_MODE_* constants.

  If the adapter does not support parts of the advertise content, INVALID_ARGUMENT is thrown.
  For example, on MacOS manufacturing data can not be specified.

  If the adapter does not allow configuration of $interval or $connection_mode an INVALID_ARGUMENT is thrown.
  */
  start_advertise
      data/AdvertisementData
      --interval/Duration=DEFAULT_INTERVAL
      --connection_mode/int=BLE_CONNECT_MODE_NONE:
    if platform == PLATFORM_MACOS:
      if interval != DEFAULT_INTERVAL or connection_mode != BLE_CONNECT_MODE_NONE: throw "INVALID_ARGUMENT"

    raw_service_classes := Array_ data.service_classes.size null

    data.service_classes.size.repeat:
      id/BleUUID := data.service_classes[it]
      raw_service_classes[it] = id.encode_for_platform_
    ble_advertise_start_
      resource_
      data.name or ""
      raw_service_classes
      data.manufacturer_data
      interval.in_us
      connection_mode

    state := resource_state_.wait_for_state ADVERTISE_START_SUCEEDED_EVENT_ | ADVERTISE_START_FAILED_EVENT_
    if (state & ADVERTISE_START_FAILED_EVENT_) != 0: throw "Failed to start advertising"

  /**
    Stops advertising.
  */
  stop_advertise:
    ble_advertise_stop_ resource_

  /**
    Adds a new service to the peripheral identified by $uuid. The returned service should be configured with
    the appropriate characteristics and then started.
  */

  add_service uuid/BleUUID -> LocalService:
    return LocalService this uuid

  wait_for_client_connected -> none:
    resource_state_.wait_for_state CONNECTED_EVENT_
    resource_state_.clear_state CONNECTED_EVENT_

  wait_for_client_disconnected -> none:
    resource_state_.wait_for_state DISCONNECTED_EVENT_
    resource_state_.clear_state DISCONNECTED_EVENT_


class AdapterInformation:
  identifier/string
  address/ByteArray
  supports_central_role/bool
  supports_peripheral_role/bool
  handle_/any
  constructor .identifier .address .supports_central_role .supports_peripheral_role .handle_:

class Adapter:
  static adapters -> List/*<AdapterInfo>*/:
    return ble_retrieve_adpaters_.map:
      AdapterInformation it[0] it[1] it[2] it[3] it[4]

  adapter_information/AdapterInformation?
  resource_group_/any
  central_manager_/CentralManager? := null
  peripheral_manager_/PeripheralManager? := null
  constructor .adapter_information=null:
    if not adapter_information:
      adapter_information = Adapter.adapters[0]
    resource_group_ = ble_init_ adapter_information.handle_

  central_manager -> CentralManager:
    if not adapter_information.supports_central_role: throw "NOT_SUPPORTED"
    if not central_manager_: central_manager_ = CentralManager this
    return central_manager_

  peripheral_manager -> PeripheralManager:
    if not adapter_information.supports_peripheral_role: throw "NOT_SUPPORTED"
    if not peripheral_manager_: peripheral_manager_ = PeripheralManager this
    return peripheral_manager_;

// General synchronisation events
READY_EVENT_                     ::= 1 << 0

// Manager lifecycle events
STARTED_EVENT_                   ::= 1 << 0

// Central Manager Events
COMPLETED_EVENT_                 ::= 1 << 1
DISCOVERY_EVENT_                 ::= 1 << 2

// Remote Device Events
CONNECTED_EVENT_                 ::= 1 << 3
CONNECT_FAILED_EVENT_            ::= 1 << 4
DISCONNECTED_EVENT_              ::= 1 << 5
SERVICES_DISCOVERED_EVENT_       ::= 1 << 6
READY_TO_SEND_WITHOUT_RESPONSE_EVENT_ ::= 1<<13

// Remote Service events
CHARACTERISTIS_DISCOVERED_EVENT_ ::= 1 << 7

// Remote Characteristics events
VALUE_DATA_READY_EVENT_          ::= 1 << 9
VALUE_DATA_READ_FAILED_EVENT_    ::= 1 << 10
DESCRIPTORS_DISCOVERED_EVENT_    ::= 1 << 8
VALUE_WRITE_SUCCEEDED_EVENT_     ::= 1 << 11
VALUE_WRITE_FAILED_EVENT_        ::= 1 << 12
SUBSCRIPTION_OPERATION_SUCCEEDED_::= 1 << 14
SUBSCRIPTION_OPERATION_FAILED_   ::= 1 << 15

// PERIPHERAL_MANAGER_EVENT
ADVERTISE_START_SUCEEDED_EVENT_         ::= 1 << 16
ADVERTISE_START_FAILED_EVENT_    ::= 1 << 17
SERVICE_ADD_SUCCEEDED_EVENT_     ::= 1 << 18
SERVICE_ADD_FAILED_EVENT_        ::= 1 << 19
DATA_RECEIVED_EVENT_             ::= 1 << 20

wait_for_ready_ resource_state/ResourceState_:
  resource_state.wait_for_state READY_EVENT_
  resource_state.clear_state READY_EVENT_


order_attributes_ input/List/*<BleUUID>*/ output/List/*<Attribute>*/ -> List:
  map := {:}
  output.do: | attribute/Attribute | map[attribute.uuid] = attribute
  return input.map: | uuid/BleUUID | map.get uuid

class Resource_:
  resource_/any? := null
  resource_state_/ResourceState_

  constructor resource_group_ .resource_:
    resource_state_ = ResourceState_ resource_group_ resource_
    add_finalizer this :: this.close_

  close_:
    if resource_:
      try:
        ble_release_resource_ resource_
        resource_state_.dispose
        resource_ = null
      finally:
        remove_finalizer this

ble_set_preferred_mtu_ mtu:
  #primitive.ble.set_preferred_mtu

ble_init_ adapter:
  #primitive.ble.init

ble_retrieve_adpaters_:
  if platform == PLATFORM_FREERTOS or platform == PLATFORM_MACOS:
    return [["default",#[], true, true, null]]
  throw "Unsuported platform"

ble_create_peripheral_manager_ resource_group:
  #primitive.ble.create_peripheral_manager

ble_create_central_manager_ resource_group:
  #primitive.ble.create_central_manager

ble_close_ resource_group:
  #primitive.ble.close

ble_release_resource_ resource:
  #primitive.ble.release_resource

ble_scan_start_ central_manager duration_us:
  #primitive.ble.scan_start

ble_scan_next_ central_manager:
  #primitive.ble.scan_next

ble_scan_stop_ central_manager:
  #primitive.ble.scan_stop

ble_connect_ resource_group address:
  #primitive.ble.connect

ble_disconnect_ device:
  #primitive.ble.disconnect


ble_discover_services_ device service_uuids:
  #primitive.ble.discover_services

ble_discover_services_result_ device:
  #primitive.ble.discover_services_result

ble_discover_characteristics_ service characteristics_uuids:
  #primitive.ble.discover_characteristics

ble_discover_characteristics_result_ service:
  #primitive.ble.discover_characteristics_result

ble_discover_descriptors_ service:
  #primitive.ble.discover_descriptors

ble_discover_descriptors_result_ service:
  #primitive.ble.discover_descriptors_result

ble_request_characteristic_read_ characteristic:
  #primitive.ble.request_characteristic_read

ble_get_characteristic_value_ characteristic:
  #primitive.ble.get_characteristic_value

ble_get_characteristic_error_ characteristic:
  #primitive.ble.get_characteristic_error

ble_write_characteristic_value_ characteristic value with_response:
  return ble_run_with_quota_backoff_:
    ble_write_characteristic_value__ characteristic value with_response

ble_write_characteristic_value__ characteristic value with_response:
  #primitive.ble.write_characteristic_value

ble_set_characteristic_notify_ characteristic value:
  #primitive.ble.set_characteristic_notify

ble_advertise_start_ peripheral_manager name services manufacturer_data interval connection_mode:
  #primitive.ble.advertise_start

ble_advertise_stop_ peripheral_manager:
  #primitive.ble.advertise_stop

ble_add_service_ peripheral_manager uuid:
  #primitive.ble.add_service

ble_add_service_characteristic_ service_resource uuid properties permission value:
  return ble_run_with_quota_backoff_:
    ble_add_service_characteristic__ service_resource uuid properties permission value
  unreachable

ble_add_service_characteristic__ service_resource uuid properties permission value:
  #primitive.ble.add_service_characteristic

ble_deploy_service_ service:
  #primitive.ble.deploy_service

ble_set_characteristics_value_ characteristic new_value -> none:
  ble_run_with_quota_backoff_:
    ble_set_characteristics_value__ characteristic new_value

ble_set_characteristics_value__ characteristic new_value:
  #primitive.ble.set_characteristics_value

ble_notify_characteristics_value_ characteristic new_value:
  #primitive.ble.notify_characteristics_value

ble_get_mtu_ characteristic:
  #primitive.ble.get_att_mtu



ble_platform_requires_uuid_as_byte_array_:
  return platform == PLATFORM_FREERTOS

ble_run_with_quota_backoff_ [block]:
  start := Time.monotonic_us
  while true:
    catch --unwind=(: it != "QUOTA_EXCEEDED"): return block.call
    sleep --ms=10
    if Time.monotonic_us - start > 2_000_000: throw DEADLINE_EXCEEDED_ERROR
