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

/**
A BLE Universally Unique ID.

UUIDs are used to identify services, characteristics and descriptions.

UUIDs can have different sizes, with 16-bit and 128-bit the most common ones.
The 128-bit UUID is referred to as the vendor specific UUID. These must be used when
  making custom services or characteristics.

16-bit UUIDs of the form "XXXX" are short-hands for "0000XXXX-0000-1000-8000-00805F9B34FB",
  where "00000000-0000-1000-8000-00805F9B34FB" comes from the BLE standard and is called
  the "base UUID"

See https://btprodspecificationrefs.blob.core.windows.net/assigned-values/16-bit%20UUID%20Numbers%20Document.pdf
  for a list of the available 16-bit UUIDs.
*/
class BleUuid:
  data_/any
  constructor .data_:
    if data_ is ByteArray:
      if data_.size != 2 and data_.size != 4 and data_.size != 16: throw "INVALID UUID"
    else if data_ is string:
      if data_.size != 4 and data_.size != 8 and data_.size != 36: throw "INVALID UUID"
      if data_.size == 36:
        uuid.parse data_ // This throws an exception if the format is incorrect.
      else:
        if (catch: hex.decode data_):
          throw "INVALID UUID $data_"
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
    return to_byte_array.hash_code

  operator== other/BleUuid:
    return to_byte_array == other.to_byte_array

/**
An attribute is the smallest data entity of GATT (Generic Attribute Profile).

Each attribute is addressable (just like registers of some i2c devices) by its handle, the $uuid.
The UUID 0x0000 denotes an invalid handle.

Services ($RemoteService, $LocalService), characteristics ($RemoteCharacteristic, $LocalCharacteristic),
  and descriptors ($RemoteDescriptor, $LocalDescriptor) are all different types of attributes.

Conceptually, attributes are on the server, and can be accessed (read and/or written) by the client.
*/
interface Attribute:
  uuid -> BleUuid

BLE_CONNECT_MODE_NONE          ::= 0
BLE_CONNECT_MODE_DIRECTIONAL   ::= 1
BLE_CONNECT_MODE_UNDIRECTIONAL ::= 2

BLE_DEFAULT_PREFERRED_MTU_     ::= 23

/**
Advertisement data as either sent by advertising or received through scanning.

The size of an advertisement packet is limited to 31 bytes. This includes the name
  and bytes that are required to structure the packet.
*/
class AdvertisementData:
  /**
  The advertised name of the device.
  */
  name/string?

  /**
  Advertised service classes as a list of $BleUuid.
  */
  service_classes/List

  /**
  Advertised manufacturer-specific data.
  */
  manufacturer_data/ByteArray

  /**
  Whether connections are allowed.
  */
  connectable/bool

  constructor --.name=null --.service_classes=[] --.manufacturer_data=#[] --.connectable=false --check_size=true:
    size := 0
    if name: size += 2 + name.size
    service_classes.do: | uuid/BleUuid |
      size += 2 + uuid.to_byte_array.size
    if not manufacturer_data.is_empty: size += 2 + manufacturer_data.size
    if size > 31 and check_size: throw "PACKET_SIZE_EXCEEDED"

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

CHARACTERISTIC_PROPERTY_BROADCAST                    ::= 0x0001
CHARACTERISTIC_PROPERTY_READ                         ::= 0x0002
CHARACTERISTIC_PROPERTY_WRITE_WITHOUT_RESPONSE       ::= 0x0004
CHARACTERISTIC_PROPERTY_WRITE                        ::= 0x0008
CHARACTERISTIC_PROPERTY_NOTIFY                       ::= 0x0010
CHARACTERISTIC_PROPERTY_INDICATE                     ::= 0x0020
CHARACTERISTIC_PROPERTY_AUTHENTICATED_SIGNED_WRITES  ::= 0x0040
CHARACTERISTIC_PROPERTY_EXTENDED_PROPERTIES          ::= 0x0080
CHARACTERISTIC_PROPERTY_NOTIFY_ENCRYPTION_REQUIRED   ::= 0x0100
CHARACTERISTIC_PROPERTY_INDICATE_ENCRYPTION_REQUIRED ::= 0x0200

CHARACTERISTIC_PERMISSION_READ                       ::= 0x01
CHARACTERISTIC_PERMISSION_WRITE                      ::= 0x02
CHARACTERISTIC_PERMISSION_READ_ENCRYPTED             ::= 0x04
CHARACTERISTIC_PERMISSION_WRITE_ENCRYPTED            ::= 0x08

class RemoteDescriptor extends RemoteReadWriteElement_ implements Attribute:
  characteristic/RemoteCharacteristic
  uuid/BleUuid

  constructor.private_ .characteristic .uuid descriptor:
    super characteristic.service descriptor

  /**
  Reads the value of the descriptor on the remote device.
  */
  read -> ByteArray?:
    return request_read_

  /**
  Writes the value of the descriptor on the remote device.
  */
  write value/ByteArray -> none:
    write_ value --expects_response=false

/**
A remote characteristic belonging to a remote service.
*/
class RemoteCharacteristic extends RemoteReadWriteElement_ implements Attribute:
  service/RemoteService
  uuid/BleUuid
  properties/int
  discovered_descriptors/List := []

  constructor.private_ .service .uuid .properties characteristic:
    super service characteristic

  /**
  Reads the value of the characteristic on the remote device.
  */
  read -> ByteArray?:
    if properties & CHARACTERISTIC_PROPERTY_READ == 0:
      throw "Characteristic does not support reads"

    return request_read_

  /**
  Waits until the remote device sends a notification or indication on the characteristics. Returns the
    notified/indicated value.
  See $subscribe.
  */
  wait_for_notification -> ByteArray?:
    if properties & (CHARACTERISTIC_PROPERTY_INDICATE | CHARACTERISTIC_PROPERTY_NOTIFY) == 0:
      throw "Characteristic does not support notifications or indications"

    while true:
      resource_state_.clear_state VALUE_DATA_READY_EVENT_
      buf := ble_get_value_ resource_
      if buf: return buf
      state := resource_state_.wait_for_state VALUE_DATA_READY_EVENT_ | VALUE_DATA_READ_FAILED_EVENT_ | DISCONNECTED_EVENT_
      if state & VALUE_DATA_READ_FAILED_EVENT_ != 0: throw_error_
      if state & DISCONNECTED_EVENT_ != 0: throw "Disconnected"

  /**
  Writes the value of the characteristic on the remote device.
  */
  write value/ByteArray -> none:
    if (properties & (CHARACTERISTIC_PROPERTY_WRITE
                      | CHARACTERISTIC_PROPERTY_WRITE_WITHOUT_RESPONSE)) == 0:
      throw "Characteristic does not support write"

    write_ value --expects_response=(properties & CHARACTERISTIC_PROPERTY_WRITE) != 0

  /**
  Requests to subscribe on this characteristic.

  This will either enable notifications or indications depending on $properties. If both, indications
    and notifications, are enabled, subscribes to notifications.
  */
  subscribe -> none:
    set_notify_subscription_ --subscribe=true

  /**
  Unsubscribes from a notification or indications on the characteristics.
    See $subscribe.
  */
  unsubscribe -> none:
    set_notify_subscription_ --subscribe=false

  set_notify_subscription_ --subscribe/bool -> none:
    if (properties & (CHARACTERISTIC_PROPERTY_INDICATE
                    | CHARACTERISTIC_PROPERTY_NOTIFY)) == 0:
      throw "Characteristic does not support notification or indication"
    resource_state_.clear_state  SUBSCRIPTION_OPERATION_FAILED_
    ble_set_characteristic_notify_ resource_ subscribe
    state := resource_state_.wait_for_state SUBSCRIPTION_OPERATION_SUCCEEDED_ | SUBSCRIPTION_OPERATION_FAILED_
    if state & SUBSCRIPTION_OPERATION_FAILED_ != 0:
      throw_error_

  /**
  Discovers all descriptors for this characteristic.
  */
  discover_descriptors -> List:
    resource_state_.clear_state DESCRIPTORS_DISCOVERED_EVENT_
    ble_discover_descriptors_ resource_
    state := wait_for_state_with_gc_ DESCRIPTORS_DISCOVERED_EVENT_
                                   | DISCONNECTED_EVENT_
                                   | DISCOVERY_OPERATION_FAILED_
    if state & DISCONNECTED_EVENT_ != 0:
      throw "BLE disconnected"
    else if state & DISCOVERY_OPERATION_FAILED_ != 0:
      throw_error_

    discovered_descriptors.add_all
        List.from
            (ble_discover_descriptors_result_ resource_).map:
                RemoteDescriptor.private_ this (BleUuid it[0]) it[1]

    return discovered_descriptors

  /**
  The negotiated mtu on the characteristics.
  On MacOS this is the maximum payload.
  On ESP32 this is the raw mtu value. Two of these bytes are needed for status information, and the
    maximum payload on ESP32 is two bytes smaller than this value.
  */
  mtu -> int:
    return ble_get_att_mtu_ resource_

/**
A service connected to a remote device through a client.
*/
class RemoteService extends Resource_ implements Attribute:
  /** The ID of the remote service. */
  uuid/BleUuid

  device/RemoteDevice

  discovered_characteristics/List := []

  constructor.private_ .device .uuid service_:
    super device.manager.adapter.resource_group_ service_

  /**
  Discovers characteristics on the remote service by looking up the handle of the given $characteristic_uuids.

  If $characteristic_uuids is empty all characteristics for the service are discovered.

  Note: Some platforms only support an empty list or a list of size 1. If the platform is limited, this method
    throws.
  */
  discover_characteristics characteristic_uuids/List=[] -> List:
    resource_state_.clear_state CHARACTERISTIS_DISCOVERED_EVENT_
    raw_characteristics_uuids := characteristic_uuids.map: | uuid/BleUuid | uuid.encode_for_platform_
    ble_discover_characteristics_ resource_ (Array_.ensure raw_characteristics_uuids)
    state := wait_for_state_with_gc_ CHARACTERISTIS_DISCOVERED_EVENT_
                                   | DISCONNECTED_EVENT_
                                   | DISCOVERY_OPERATION_FAILED_
    if state & DISCONNECTED_EVENT_ != 0:
      throw "BLE disconnected"
    else if state & DISCOVERY_OPERATION_FAILED_ != 0:
      throw_error_

    discovered_characteristics.add_all
        List.from
            (ble_discover_characteristics_result_ resource_).map:
              RemoteCharacteristic.private_ this (BleUuid it[0]) it[1] it[2]

    return order_attributes_ characteristic_uuids discovered_characteristics


/**
A remote connected device.
*/
class RemoteDevice extends Resource_:
  manager/Central
  /**
  The address of the remote device the client is connected to. The type of the address is platform dependent.
  */
  address/any

  discovered_services/List := []

  constructor.private_ .manager .address:
    device := ble_connect_ manager.resource_ address
    super manager.adapter.resource_group_ device --auto_release
    state := resource_state_.wait_for_state CONNECTED_EVENT_ | CONNECT_FAILED_EVENT_
    if state & CONNECT_FAILED_EVENT_ != 0:
      close_
      throw "BLE connection failed"
      // TODO: Possible leak of the gatt_ resource on connection failures.

  /**
  Discovers remote services by looking up the given $service_uuids on the remote device.

  If $service_uuids is empty all services for the device are discovered.

  Note: Some platforms only support an empty list or a list of size 1. If the platform is limited, this method
    throws.
  */
  discover_services service_uuids/List=[] -> List:
    resource_state_.clear_state SERVICES_DISCOVERED_EVENT_
    raw_service_uuids := service_uuids.map: | uuid/BleUuid | uuid.encode_for_platform_
    ble_discover_services_ resource_ (Array_.ensure raw_service_uuids)
    state := wait_for_state_with_gc_ SERVICES_DISCOVERED_EVENT_
                                   | DISCONNECTED_EVENT_
                                   | DISCOVERY_OPERATION_FAILED_
    if state & DISCONNECTED_EVENT_ != 0:
      throw "BLE disconnected"
    else if state & DISCOVERY_OPERATION_FAILED_ != 0:
      throw_error_

    discovered_services.add_all
        (ble_discover_services_result_ resource_).map:
          RemoteService.private_ this (BleUuid it[0]) it[1]

    return order_attributes_ service_uuids discovered_services

  /**
  Disconnects from the remote device.
  */
  close:
    ble_disconnect_ resource_
    resource_state_.wait_for_state DISCONNECTED_EVENT_
    close_

  mtu -> int:
    return ble_get_att_mtu_ resource_

/**
Defines a BLE service with characteristics.
*/
class LocalService extends Resource_ implements Attribute:
  /**
  The UUID of the service.
  */
  uuid/BleUuid

  peripheral_manager/Peripheral

  deployed_/bool := false

  constructor .peripheral_manager .uuid:
    resource := ble_add_service_ peripheral_manager.resource_ uuid.encode_for_platform_
    super peripheral_manager.adapter.resource_group_ resource --auto_release

  /**
  Adds a characteristic to this service with the given parameters.
  $uuid is the uuid of the characteristic
  $properties is one of the CHARACTERISTIC_PROPERTY_* values (see
    $CHARACTERISTIC_PROPERTY_BROADCAST and similar).
  $permissions is one of the CHARACTERISTIC_PERMISSIONS_* values (see
    $CHARACTERISTIC_PERMISSION_READ and similar).
  if $value is specified, it is used as the initial value for the characteristic.
  Throws if the service is already deployed.
  */
  add_characteristic
      uuid/BleUuid
      --properties/int
      --permissions/int
      --value/ByteArray=#[] -> LocalCharacteristic:
    if deployed_: throw "Service is already deployed"
    return LocalCharacteristic this uuid properties permissions value

  /**
  Convenience method to add a read-only characteristic with the given $uuid and $value.
  */
  add_read_only_characteristic uuid/BleUuid --value/ByteArray -> LocalCharacteristic:
    return add_characteristic
        uuid
        --properties=CHARACTERISTIC_PROPERTY_READ
        --permissions=CHARACTERISTIC_PERMISSION_READ
        --value=value

  /**
  Convenience method to add a write-only characteristic with the given $uuid that can $requires_response for each write.
  */
  add_write_only_characteristic uuid/BleUuid requires_response/bool=false -> LocalCharacteristic:
    properties := requires_response
      ? CHARACTERISTIC_PROPERTY_WRITE
      : CHARACTERISTIC_PROPERTY_WRITE_WITHOUT_RESPONSE
    return add_characteristic
        uuid
        --properties=properties
        --permissions=CHARACTERISTIC_PERMISSION_WRITE

  /**
  Convenience method to add a notification characteristic with the given $uuid. See $add_characteristic.
  */
  add_notification_characteristic uuid/BleUuid -> LocalCharacteristic:
    return add_characteristic
        uuid
        --properties=CHARACTERISTIC_PROPERTY_NOTIFY
        --permissions=CHARACTERISTIC_PERMISSION_READ

  /**
  Convenience method to add an indication characteristic with the given $uuid. See $add_characteristic.
  */
  add_indication_characteristic  uuid/BleUuid  -> LocalCharacteristic:
    return add_characteristic
        uuid
        --properties=CHARACTERISTIC_PROPERTY_INDICATE
        --permissions=CHARACTERISTIC_PERMISSION_READ

  /**
  Deploys this service.

  After deployment, no more characteristics can be added. See $add_characteristic.
  */
  deploy:
    ble_deploy_service_ resource_
    state := resource_state_.wait_for_state (SERVICE_ADD_SUCCEEDED_EVENT_ | SERVICE_ADD_FAILED_EVENT_)
    if state & SERVICE_ADD_FAILED_EVENT_ != 0: throw "Failed to add service"
    deployed_ = true


class LocalCharacteristic extends LocalReadWriteElement_ implements Attribute:
  uuid/BleUuid

  permissions/int
  properties/int
  service/LocalService

  constructor .service .uuid .properties .permissions value/ByteArray:
    resource := ble_add_characteristic_ service.resource_ uuid.encode_for_platform_ properties permissions value
    super service resource

  /**
  Sends a notification or an indication, based on the properties of the characteristic.

  If the characteristic supports both indications and notifications, then a notification is sent.
  */
  write value/ByteArray:
    if permissions & CHARACTERISTIC_PERMISSION_READ == 0: throw "Invalid permission"

    if (properties & (CHARACTERISTIC_PROPERTY_NOTIFY | CHARACTERISTIC_PROPERTY_INDICATE)) != 0:
      clients := ble_get_subscribed_clients resource_
      clients.do:
        ble_notify_characteristics_value_ resource_ it value
    else:
      ble_set_value_ resource_ value

  /**
  Reads a value that is written to this characteristic.

  Waits until a client writes a value.
  */
  read -> ByteArray:
    if (permissions & CHARACTERISTIC_PERMISSION_WRITE) == 0:
      throw "Invalid permission"
    return read_

  /**
  Adds a descriptor to this characteristic.
  $uuid is the uuid of the descriptor
  $properties is one of the CHARACTERISTIC_PROPERTY_* values (see
    $CHARACTERISTIC_PROPERTY_BROADCAST and similar).
  $permissions is one of the CHARACTERISTIC_PERMISSIONS_* values (see
    $CHARACTERISTIC_PERMISSION_READ and similar).
  if $value is specified, it is used as the initial value for the characteristic.
  Throws if the service is already deployed.
  */
  add_descriptor uuid/BleUuid properties/int permissions/int value/ByteArray?=null -> LocalDescriptor:
    if service.deployed_: throw "Service is already deployed"
    return LocalDescriptor this uuid properties permissions value


class LocalDescriptor extends LocalReadWriteElement_ implements Attribute:
  uuid/BleUuid
  characteristic/LocalCharacteristic
  permissions/int
  properties/int

  constructor .characteristic .uuid .properties .permissions value:
    resource :=  ble_add_descriptor_ characteristic.resource_ uuid.encode_for_platform_ properties permissions value
    super characteristic.service resource

  write value/ByteArray:
    if (permissions & CHARACTERISTIC_PERMISSION_WRITE) == 0:
      throw "Invalid permission"
    ble_set_value_ resource_ value

  read -> ByteArray:
    if (permissions & CHARACTERISTIC_PERMISSION_WRITE) == 0:
      throw "Invalid permission"
    return read_


/**
The manager for creating client connections.
*/
class Central extends Resource_:
  adapter/Adapter

  constructor .adapter:
    resource := ble_create_central_manager_ adapter.resource_group_
    super adapter.resource_group_ resource --auto_release
    resource_state_.wait_for_state STARTED_EVENT_

  /**
  Connects to the remote device with the given $address.

  Connections cannot be established while a scan is ongoing.
  */
  connect address/any -> RemoteDevice:
    return RemoteDevice.private_ this address


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
        state := wait_for_state_with_gc_ DISCOVERY_EVENT_ | COMPLETED_EVENT_
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
                BleUuid raw_service_classes[it]

        discovery := RemoteScannedDevice
          next[0]
          next[1]
          AdvertisementData
            --name=next[2]
            --service_classes=service_classes
            --manufacturer_data=(next[4]?next[4]:#[])
            --connectable=next[5]
            --check_size=false
        block.call discovery
    finally:
      ble_scan_stop_ resource_
      resource_state_.wait_for_state COMPLETED_EVENT_

/**
The manager for advertising and managing local services.
*/
class Peripheral extends Resource_:
  static DEFAULT_INTERVAL ::= Duration --us=46875
  adapter/Adapter

  constructor .adapter:
    resource := ble_create_peripheral_manager_ adapter.resource_group_
    super adapter.resource_group_ resource --auto_release
    resource_state_.wait_for_state STARTED_EVENT_

  /**
  Starts advertising the $data.

  The data is advertised once every $interval.

  The advertise includes the given $connection_mode, which must be one
    of the BLE_CONNECT_MODE_* constants (see $BLE_CONNECT_MODE_NONE and similar).

  Throws, If the adapter does not support parts of the advertise content.
  For example, on MacOS manufacturing data can not be specified.

  Throws, If the adapter does not allow configuration of $interval or $connection_mode.
  */
  start_advertise
      data/AdvertisementData
      --interval/Duration=DEFAULT_INTERVAL
      --connection_mode/int=BLE_CONNECT_MODE_NONE:
    if platform == PLATFORM_MACOS:
      if interval != DEFAULT_INTERVAL or connection_mode != BLE_CONNECT_MODE_NONE: throw "INVALID_ARGUMENT"

    raw_service_classes := Array_ data.service_classes.size null

    data.service_classes.size.repeat:
      id/BleUuid := data.service_classes[it]
      raw_service_classes[it] = id.encode_for_platform_
    ble_advertise_start_
      resource_
      data.name or ""
      raw_service_classes
      data.manufacturer_data
      interval.in_us
      connection_mode

    state := resource_state_.wait_for_state ADVERTISE_START_SUCEEDED_EVENT_ | ADVERTISE_START_FAILED_EVENT_
    if state & ADVERTISE_START_FAILED_EVENT_ != 0: throw "Failed to start advertising"

  /**
  Stops advertising.
  */
  stop_advertise:
    ble_advertise_stop_ resource_

  /**
  Adds a new service to the peripheral identified by $uuid. The returned service should be configured with
    the appropriate characteristics and then be deployed.
  */
  add_service uuid/BleUuid -> LocalService:
    return LocalService this uuid


class AdapterMetadata:
  identifier/string
  address/ByteArray
  supports_central_role/bool
  supports_peripheral_role/bool
  handle_/any

  constructor.private_ .identifier .address .supports_central_role .supports_peripheral_role .handle_:

  adapter -> Adapter:
    return Adapter.private_ this

/**
An adapter represents the chip or peripheral that is used to communicate over BLE.
On the ESP32 it is the integrated peripheral. On desktops it is provided by the operating system, and
  can be a USB chip, or an integrated chip of laptops.
*/
class Adapter:
  static discover_adapter_metadata -> List/*<AdapterMetadata>*/:
    return ble_retrieve_adpaters_.map:
      AdapterMetadata.private_ it[0] it[1] it[2] it[3] it[4]

  adapter_metadata/AdapterMetadata?
  resource_group_/any
  central_/Central? := null
  peripheral_/Peripheral? := null

  constructor: return discover_adapter_metadata[0].adapter

  constructor.private_ .adapter_metadata:
    resource_group_ = ble_init_ adapter_metadata.handle_

  /**
  The central manager handles connections to remote peripherals.
  It is responsible for scanning, discovering and connecting to other devices.
  */
  central -> Central:
    if not adapter_metadata.supports_central_role: throw "NOT_SUPPORTED"
    if not central_: central_ = Central this
    return central_

  /**
  The peripheral manager is used to advertise and publish local services.
  */
  peripheral -> Peripheral:
    if not adapter_metadata.supports_peripheral_role: throw "NOT_SUPPORTED"
    if not peripheral_: peripheral_ = Peripheral this
    return peripheral_;

  set_preferred_mtu mtu/int:
    ble_set_preferred_mtu_ mtu

// General events
MALLOC_FAILED_                        ::= 1 << 22

// Manager lifecycle events
STARTED_EVENT_                        ::= 1 << 0

// Central Manager Events
COMPLETED_EVENT_                      ::= 1 << 1
DISCOVERY_EVENT_                      ::= 1 << 2
DISCOVERY_OPERATION_FAILED_           ::= 1 << 21

// Remote Device Events
CONNECTED_EVENT_                      ::= 1 << 3
CONNECT_FAILED_EVENT_                 ::= 1 << 4
DISCONNECTED_EVENT_                   ::= 1 << 5
SERVICES_DISCOVERED_EVENT_            ::= 1 << 6
READY_TO_SEND_WITHOUT_RESPONSE_EVENT_ ::= 1 << 13

// Remote Service events
CHARACTERISTIS_DISCOVERED_EVENT_      ::= 1 << 7

// Remote Characteristics events
VALUE_DATA_READY_EVENT_               ::= 1 << 9
VALUE_DATA_READ_FAILED_EVENT_         ::= 1 << 10
DESCRIPTORS_DISCOVERED_EVENT_         ::= 1 << 8
VALUE_WRITE_SUCCEEDED_EVENT_          ::= 1 << 11
VALUE_WRITE_FAILED_EVENT_             ::= 1 << 12
SUBSCRIPTION_OPERATION_SUCCEEDED_     ::= 1 << 14
SUBSCRIPTION_OPERATION_FAILED_        ::= 1 << 15

// Peripheral Manager events
ADVERTISE_START_SUCEEDED_EVENT_       ::= 1 << 16
ADVERTISE_START_FAILED_EVENT_         ::= 1 << 17
SERVICE_ADD_SUCCEEDED_EVENT_          ::= 1 << 18
SERVICE_ADD_FAILED_EVENT_             ::= 1 << 19
DATA_RECEIVED_EVENT_                  ::= 1 << 20



order_attributes_ input/List/*<BleUUID>*/ output/List/*<Attribute>*/ -> List:
  map := {:}
  if input.is_empty: return output
  output.do: | attribute/Attribute | map[attribute.uuid] = attribute
  // Input might contain Uuids that where never discovered, so make sure to use
  // the non-throwing version of map.get.
  return input.map: | uuid/BleUuid | map.get uuid

class Resource_:
  resource_/any? := null
  resource_state_/ResourceState_

  constructor resource_group_ .resource_ --auto_release/bool=false:
    resource_state_ = ResourceState_ resource_group_ resource_
    if auto_release:
      add_finalizer this ::
        this.close_

  close_:
    if resource_:
      try:
        resource := resource_
        resource_ = null
        resource_state_.dispose
        ble_release_resource_ resource_
      finally:
        remove_finalizer this

  throw_error_:
    ble_get_error_ resource_

  wait_for_state_with_gc_ bits:
    while true:
      state := resource_state_.wait_for_state bits | MALLOC_FAILED_
      if state & MALLOC_FAILED_ != 0:
        ble_gc_ resource_
      else:
        return state

class RemoteReadWriteElement_ extends Resource_:
  remote_service_/RemoteService

  constructor .remote_service_ resource:
    super remote_service_.device.manager.adapter.resource_group_ resource

  write_ value/ByteArray --expects_response/bool:
    while true:
      remote_service_.device.resource_state_.clear_state READY_TO_SEND_WITHOUT_RESPONSE_EVENT_
      resource_state_.clear_state VALUE_WRITE_FAILED_EVENT_ | VALUE_WRITE_SUCCEEDED_EVENT_
      result := ble_write_value_ resource_ value expects_response
      if result == 0: return // Write without response success.
      if result == 1: // Write with response.
        state := resource_state_.wait_for_state VALUE_WRITE_FAILED_EVENT_ | VALUE_WRITE_SUCCEEDED_EVENT_
        if state & VALUE_WRITE_FAILED_EVENT_ != 0: throw_error_
        return
      if result == 2: // Write without response, needs to wait for device ready.
        remote_service_.device.resource_state_.wait_for_state READY_TO_SEND_WITHOUT_RESPONSE_EVENT_

  request_read_:
    resource_state_.clear_state VALUE_DATA_READY_EVENT_
    ble_request_read_ resource_
    state := resource_state_.wait_for_state VALUE_DATA_READY_EVENT_ | VALUE_DATA_READ_FAILED_EVENT_
    if state & VALUE_DATA_READ_FAILED_EVENT_ != 0: throw_error_
    return ble_get_value_ resource_


class LocalReadWriteElement_ extends Resource_:
  constructor service/LocalService resource:
    super service.peripheral_manager.adapter.resource_group_ resource

  read_ -> ByteArray:
    resource_state_.clear_state DATA_RECEIVED_EVENT_
    while true:
      buf := ble_get_value_ resource_
      if buf: return buf
      resource_state_.wait_for_state DATA_RECEIVED_EVENT_


ble_retrieve_adpaters_:
  if platform == PLATFORM_FREERTOS or platform == PLATFORM_MACOS:
    return [["default", #[], true, true, null]]
  throw "Unsupported platform"

ble_init_ adapter:
  #primitive.ble.init

ble_create_central_manager_ resource_group:
  #primitive.ble.create_central_manager

ble_create_peripheral_manager_ resource_group:
  #primitive.ble.create_peripheral_manager

ble_close_ resource_group:
  #primitive.ble.close

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

ble_release_resource_ resource:
  #primitive.ble.release_resource

ble_discover_services_ device service_uuids:
  #primitive.ble.discover_services

ble_discover_services_result_ device:
  #primitive.ble.discover_services_result

ble_discover_characteristics_ service characteristics_uuids:
  #primitive.ble.discover_characteristics

ble_discover_characteristics_result_ service:
  #primitive.ble.discover_characteristics_result

ble_discover_descriptors_ characteristic:
  #primitive.ble.discover_descriptors

ble_discover_descriptors_result_ characteristic:
  #primitive.ble.discover_descriptors_result

ble_request_read_ resource:
  #primitive.ble.request_read

ble_get_value_ characteristic:
  #primitive.ble.get_value

ble_write_value_ characteristic value with_response:
  return ble_run_with_quota_backoff_:
    ble_write_value__ characteristic value with_response

ble_write_value__ characteristic value with_response:
  #primitive.ble.write_value

ble_set_characteristic_notify_ characteristic value:
  #primitive.ble.set_characteristic_notify

ble_advertise_start_ peripheral_manager name services manufacturer_data interval connection_mode:
  #primitive.ble.advertise_start

ble_advertise_stop_ peripheral_manager:
  #primitive.ble.advertise_stop

ble_add_service_ peripheral_manager uuid:
  #primitive.ble.add_service

ble_add_characteristic_ service uuid properties permission value:
  return ble_run_with_quota_backoff_:
    ble_add_characteristic__ service uuid properties permission value
  unreachable

ble_add_characteristic__ service uuid properties permission value:
  #primitive.ble.add_characteristic

ble_add_descriptor_ characteristic uuid properties permission value:
  return ble_run_with_quota_backoff_:
    ble_add_descriptor__ characteristic uuid properties permission value

ble_add_descriptor__ characteristic uuid properties permission value:
  #primitive.ble.add_descriptor

ble_deploy_service_ service:
  #primitive.ble.deploy_service

ble_set_value_ characteristic new_value -> none:
  ble_run_with_quota_backoff_:
    ble_set_value__ characteristic new_value

ble_set_value__ characteristic new_value:
  #primitive.ble.set_value

ble_get_subscribed_clients characteristic:
  #primitive.ble.get_subscribed_clients

ble_notify_characteristics_value_ characteristic client new_value:
  return ble_run_with_quota_backoff_:
    ble_notify_characteristics_value__ characteristic client new_value

ble_notify_characteristics_value__ characteristic client new_value:
  #primitive.ble.notify_characteristics_value

ble_get_att_mtu_ resource:
  #primitive.ble.get_att_mtu

ble_set_preferred_mtu_ mtu:
  #primitive.ble.set_preferred_mtu

ble_get_error_ characteristic:
  #primitive.ble.get_error

ble_gc_ resource:
  #primitive.ble.gc

ble_platform_requires_uuid_as_byte_array_:
  return platform == PLATFORM_FREERTOS

ble_run_with_quota_backoff_ [block]:
  start := Time.monotonic_us
  while true:
    catch --unwind=(: it != "QUOTA_EXCEEDED"): return block.call
    sleep --ms=10
    if Time.monotonic_us - start > 2_000_000: throw DEADLINE_EXCEEDED_ERROR
