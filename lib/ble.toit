// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
import monitor
import uuid as uuid_pkg
import bytes
import monitor show ResourceState_

/**
The base BLE UUID form which 16-bit and 32-bit UUIDs are generated.
*/
UUID/uuid_pkg.Uuid ::= uuid_pkg.parse "00000000-0000-1000-8000-00805F9B34FB"

/**
Returns the fully formed 128-bit uuid from a 16-bit or 32-bit BLE uuid.
*/
uuid value/int -> uuid_pkg.Uuid:
  bytes := UUID.to_byte_array.copy
  binary.BIG_ENDIAN.put_uint32 bytes 0 value
  return uuid_pkg.Uuid bytes

/**
A 48-bit BLE advertise address.
*/
class Address:
  static HEX_TABLE_ ::= "0123456789abcdef"

  raw_/ByteArray

  constructor .raw_:

  stringify -> string:
    buffer := bytes.Buffer
    6.repeat:
      if it > 0: buffer.write_byte ':'
      byte := raw_[1 + it]
      buffer.write_byte HEX_TABLE_[byte >> 4]
      buffer.write_byte HEX_TABLE_[byte & 0xf]
    return buffer.to_string

  /**
  Returns the bytes of the address as a 6-byte ByteArray.
  */
  to_bytes -> ByteArray: return raw_[1..]

  /** Whether this address is the same as $other. */
  operator == other -> bool:
    if other is not Address: return false
    return raw_ == other.raw_

  /** A hash code for this instance. */
  hash_code -> int:
    // Use the last 3 bytes for hash.
    return raw_[6] | raw_[5] << 8 | raw_[4] << 16

BLE_CONNECT_MODE_NONE          ::= 0
BLE_CONNECT_MODE_DIRECTIONAL   ::= 1
BLE_CONNECT_MODE_UNDIRECTIONAL ::= 2

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

  constructor --.name=null --.service_classes=[] --.manufacturer_data=#[]:

/**
The BLE advertiser controlling the rate and content of the advertisement data.
*/
class Advertiser:
  static DEFAULT_INTERVAL ::= Duration --us=46875

  device/Device

  /**
  Constructs an advertiser from the given $device.
  */
  constructor .device:

  /**
  Starts advertising the data.

  The data is advertised for the given $duration and once every $interval.
    If the $duration is null, then the data is advertised indefinitely.

  The advertise will include the given $connection_mode, use one
    of the BLE_CONNECTION_MODE_* constants.

  Use $set_data to set the data.

  Only one advertiser can advertise at any given time.
  */
  start
      --duration/Duration?=null
      --interval/Duration=DEFAULT_INTERVAL
      --connection_mode/int=BLE_CONNECT_MODE_NONE:
    duration_us := duration ? (max 0 duration.in_us) : -1
    ble_advertise_start_ device.resource_group_ duration_us interval.in_us connection_mode

  /**
  Closes and stops the advertiser.
  */
  close:
    ble_advertise_stop_ device.resource_group_

  /**
  Sets the advertisement data to the given $data.

  If the advertiser is already advertising, then the new data is used for the next advertisement (see --interval for $start).
  */
  set_data data/AdvertisementData:
    raw_service_classes := Array_ data.service_classes.size null

    data.service_classes.size.repeat:
      id/uuid_pkg.Uuid := data.service_classes[it]
      raw_service_classes[it] = id.to_byte_array
    ble_advertise_config_
      device.resource_group_
      data.name or ""
      raw_service_classes
      data.manufacturer_data

  /**
  Waits for the advertiser to complete.
  */
  wait_for_done:
    device.resource_state_.wait_for_state COMPLETED_EVENT_

/**
A remote device discovered by a scanning.
*/
class RemoteDevice:
  /**
  The BLE address of the remote device.
  */
  address/Address

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

/**
A remote service connected to a remote device through a client.
*/
class RemoteService:
  client_/Client
  /** The ID of the remote service. */
  service_id/uuid_pkg.Uuid
  handle_range_/int

  /**
  Constructs a remote service from the given $client_, $service_id, and $handle_range_.
  */
  constructor .client_ .service_id .handle_range_:

  /**
  Reads a remote characteristic on the remote service by looking up the handle of the given $characteristic_uuid.

  # Advanced
  Every call to $read_characteristic downloads the characteristic from the remote device.
    It is therefore recommended to cache and reuse the value rather than calling $read_characteristic multiple times.
  */
  read_characteristic characteristic_uuid/uuid_pkg.Uuid -> RemoteCharacteristic:
    ble_request_characteristic_ client_.gatt_ handle_range_ characteristic_uuid.to_byte_array
    client_.wait_for_done_
    result := ble_request_result_ client_.gatt_
    return RemoteCharacteristic
      this
      result >> 16
      --definition_handle=result & 0xFFFF

  /**
  Reads the value of the characteristic with the given $characteristic_uuid.

  This is a convenience method that first does a characteristic lookup and then reads the value.
  */
  read_value characteristic_uuid/uuid_pkg.Uuid -> ByteArray?:
    characteristic := read_characteristic characteristic_uuid
    return characteristic.read_value

/**
A remote characteristic belonging to a remote service.
*/
class RemoteCharacteristic:
  service/RemoteService
  handle/int
  definition_handle/int

  /**
  Constructs remote characteristic from the given $service, $handle, and $definition_handle.
  */
  constructor .service .handle --.definition_handle=0:

  /**
  Reads the value of the characteristic on the remote service.

  Returns `null` if the characteristic is invalid or empty.
  */
  read_value -> ByteArray?:
    client := service.client_
    ble_request_attribute_ client.gatt_ handle
    client.wait_for_done_
    data := ble_request_data_ client.gatt_
    return data

  /**
  Writes the value of the characteristic on the remote service.
  */
  write_value value/ByteArray -> none:
    ble_send_data_ service.client_.gatt_ handle value

/**
A client connected to a remote device.
*/
class Client:
  device/Device
  /**
  The address of the remote device the client is connected to.
  */
  address/Address

  gatt_ := ?
  resource_state_/monitor.ResourceState_

  constructor .device .address:
    gatt_ = ble_get_gatt_ device.resource_group_
    resource_state_ = monitor.ResourceState_ device.resource_group_ gatt_
    ble_connect_ device.resource_group_ address.raw_ gatt_
    state := resource_state_.wait_for_state CONNECTED_EVENT_ | CONNECT_FAILED_EVENT_
    if state & CONNECT_FAILED_EVENT_ != 0:
      throw "BLE connection failed"
      // TODO Possible leak of the gatt_ resource on connection failures

  /**
  Reads a remote service by looking up the given $service_uuid on the remote device.
  */
  read_service service_uuid/uuid_pkg.Uuid -> RemoteService:
    ble_request_service_ gatt_ service_uuid.to_byte_array
    wait_for_done_
    result := ble_request_result_ gatt_
    return RemoteService this service_uuid result

  wait_for_done_:
    state := resource_state_.wait_for_state STARTED_EVENT_
    resource_state_.clear_state STARTED_EVENT_

/**
Contains definitions of the services exposed by the BLE server.
*/
class ServerConfiguration:
  resource_group_ := null
  services/List := []

  constructor:
    resource_group_ = ble_server_configuration_init_
    add_finalizer this:: ble_server_configuration_dispose_ resource_group_

  add_service uuid -> Service:
    service := Service this uuid
    services.add service
    return service

/**
Defines a BLE service with characteristics.
*/
class Service:
  /**
  The UUID of the service.

  For 16 and 32 bit UUIDs, form the BLE variant with the top-level uuid function.
  */
  uuid/uuid_pkg.Uuid

  server_configuration_/ServerConfiguration
  resource_/ByteArray?

  characteristics_/Map ::= {:}

  constructor .server_configuration_ .uuid:
    resource_ = ble_add_server_service_ server_configuration_.resource_group_ uuid.to_byte_array

  add_read_only_characteristic uuid --value=#[]-> ReadOnlyCharacteristic:
    char := ReadOnlyCharacteristic this uuid value
    characteristics_[uuid] = char
    return char

  add_write_only_characteristic uuid -> WriteOnlyCharacteristic:
    char := WriteOnlyCharacteristic this uuid
    characteristics_[uuid] = char
    return char

  add_read_write_characteristic uuid --value=#[]-> ReadWriteCharacteristic:
    char := ReadWriteCharacteristic this uuid value
    characteristics_[uuid] = char
    return char

  add_notification_characteristic uuid -> NotificationCharacteristic:
    char := NotificationCharacteristic this uuid
    characteristics_[uuid] = char
    return char

  get_characteristic uuid -> Characteristic?:
    return characteristics_.get uuid


BLE_CHR_TYPE_READ_ONLY_    ::= 1
BLE_CHR_TYPE_WRITE_ONLY_   ::= 2
BLE_CHR_TYPE_READ_WRITE_   ::= 3
BLE_CHR_TYPE_NOTIFICATION_ ::= 4

BLE_WAIT_RECV_             ::= 1 << 0
BLE_WAIT_ACCESSED_         ::= 1 << 1
BLE_WAIT_SUBSCRIBED_       ::= 1 << 2

/**
Base class of all characteristics.
*/
abstract class Characteristic:
  /**
  The UUID of the characteristic.
  */
  uuid/uuid_pkg.Uuid

  state_/ResourceState_

  constructor service/Service resource .uuid:
    state_ = ResourceState_ service.server_configuration_.resource_group_ resource

/**
Base class of characteristics that clients can write to.
*/
abstract class WritableCharacteristic extends Characteristic:
  constructor service/Service resource uuid:
    super service resource uuid

  value -> ByteArray?:
    state_.wait_for_state BLE_WAIT_RECV_
    data := ble_get_characteristics_value_ state_.resource
    state_.clear_state BLE_WAIT_RECV_
    return data

/**
A characteristic that can only be read by clients.
*/
class ReadOnlyCharacteristic extends Characteristic:
  value_/ByteArray := #[]

  constructor service/Service uuid/uuid_pkg.Uuid value/ByteArray:
    resource := ble_add_server_characteristic_ service.resource_ uuid.to_byte_array BLE_CHR_TYPE_READ_ONLY_ value
    super service resource uuid
    value_ = value

  value -> ByteArray: return value_

  value= value/ByteArray -> none:
    ble_set_characteristics_value_ state_.resource value
    value_ = value

/**
A characteristic that can only be written to by clients.
*/
class WriteOnlyCharacteristic extends WritableCharacteristic:
  constructor service/Service uuid/uuid_pkg.Uuid:
    resource := ble_add_server_characteristic_ service.resource_ uuid.to_byte_array BLE_CHR_TYPE_WRITE_ONLY_ null
    super service resource uuid

/**
A characteristic that allows both read and write by the client.
*/
class ReadWriteCharacteristic extends WritableCharacteristic:
  constructor service/Service uuid/uuid_pkg.Uuid value/ByteArray:
    resource := ble_add_server_characteristic_ service.resource_ uuid.to_byte_array BLE_CHR_TYPE_READ_WRITE_ value
    super service resource uuid

  value= value/ByteArray -> none:
    ble_set_characteristics_value_ state_.resource value


/**
A characteristic that the client can subscribe to changes on.
*/
class NotificationCharacteristic extends Characteristic:
  constructor service/Service uuid/uuid_pkg.Uuid:
    resource := ble_add_server_characteristic_ service.resource_ uuid.to_byte_array BLE_CHR_TYPE_NOTIFICATION_ null
    super service resource uuid

  value= value/ByteArray -> none:
    ble_notify_characteristics_value_ state_.resource value

/**
The local BLE device.

After construction, the BLE stack is initialized and ready to use.

If services is not empty, sets up the services for the advertiser.
*/
class Device:
  resource_group_ := ?
  resource_state_/monitor.ResourceState_? := null

  constructor.default server_configuration/ServerConfiguration?=null:
    server_configuration_resource_group := server_configuration != null
        ? server_configuration.resource_group_
        : null
    resource_group_ = ble_init_ server_configuration_resource_group
    add_finalizer this:: this.close
    try:
      gap := ble_gap_ resource_group_
      resource_state := monitor.ResourceState_ resource_group_ gap
      state := resource_state.wait_for_state STARTED_EVENT_
      resource_state_ = resource_state

    finally: | is_exception e |
      if not resource_state_: ble_close_ resource_group_

  /**
  Connects to the remote device with the given $address.

  Connections cannot be established while a scan is ongoing.
  */
  connect address/Address -> Client:
    return Client this address

  /**
  Closes the device and releases all resources associated with the BLE stack.
  */
  close:
    if resource_group_:
      try:
        ble_close_ resource_group_
        resource_group_ = null
        resource_state_.dispose
        resource_state_ = null
      finally:
        remove_finalizer this

  /**
  Initializes an advertiser for the local device.

  The returned advertiser is not started.
  */
  advertise -> Advertiser:
    return Advertiser this


  /**
  Scans for nearby devices. This method blocks while the scan is ongoing.

  Only one scan can run at a time.

  Connections cannot be established while a scan is ongoing.

  Stops the scan after the given $duration.
  */
  scan [block] --duration/Duration?=null:
    duration_us := duration ? (max 0 duration.in_us) : -1
    ble_scan_start_ resource_group_ duration_us
    try:
      while true:
        state := resource_state_.wait_for_state DISCOVERY_EVENT_ | COMPLETED_EVENT_
        next := ble_scan_next_ resource_group_
        if not next:
          resource_state_.clear_state DISCOVERY_EVENT_
          if state & COMPLETED_EVENT_ != 0: return
          continue
        service_classes := []
        raw_service_classes := next[3]
        if raw_service_classes:
          raw_service_classes.size.repeat:
            service_classes.add
              uuid_pkg.Uuid raw_service_classes[it]
        discovery := RemoteDevice
          Address next[0]
          next[1]
          AdvertisementData
            --name=next[2]
            --service_classes=service_classes
            --manufacturer_data=next[4]
        block.call discovery
    finally:
      ble_scan_stop_ resource_group_

  wait_for_client_connected -> none:
    resource_state_.wait_for_state CONNECTED_EVENT_
    resource_state_.clear_state CONNECTED_EVENT_

  wait_for_client_disconnected -> none:
    resource_state_.wait_for_state DISCONNECTED_EVENT_
    resource_state_.clear_state DISCONNECTED_EVENT_

STARTED_EVENT_              ::= 1 << 0
COMPLETED_EVENT_            ::= 1 << 1
DISCOVERY_EVENT_            ::= 1 << 2
CONNECTED_EVENT_            ::= 1 << 3
CONNECT_FAILED_EVENT_       ::= 1 << 4
DISCONNECTED_EVENT_         ::= 1 << 5

ble_init_ config_resource_group:
  #primitive.ble.init

ble_gap_ resource_group:
  #primitive.ble.gap

ble_close_ resource_group:
  #primitive.ble.close

ble_scan_start_ resource_group duration_us:
  #primitive.ble.scan_start

ble_scan_next_ resource_group:
  #primitive.ble.scan_next

ble_scan_stop_ resource_group:
  #primitive.ble.scan_stop

ble_advertise_start_ resource_group duration_us interval_us connect_mode:
  #primitive.ble.advertise_start

ble_advertise_config_ resource_group name service_classes service_data:
  #primitive.ble.advertise_config

ble_advertise_stop_ resource_group:
  #primitive.ble.advertise_stop

ble_connect_ resource_group address gatt:
  #primitive.ble.connect

ble_get_gatt_ resource_group:
  #primitive.ble.get_gatt

ble_request_result_ gatt:
  #primitive.ble.request_result

ble_request_data_ gatt:
  #primitive.ble.request_data

ble_send_data_ gatt handle value:
  #primitive.ble.send_data

ble_request_service_ gatt service_id:
  #primitive.ble.request_service

ble_request_characteristic_ gatt handle_range characteristic_id:
  #primitive.ble.request_characteristic

ble_request_attribute_ gatt handle:
  #primitive.ble.request_attribute

ble_server_configuration_init_:
  #primitive.ble.server_configuration_init

ble_server_configuration_dispose_ resource_group_:
  #primitive.ble.server_configuration_dispose

ble_add_server_service_ resource_group_ uuid:
  #primitive.ble.add_server_service

ble_add_server_characteristic_ service_resource uuid type value:
  #primitive.ble.add_server_characteristic

ble_set_characteristics_value_ gatt new_value:
  #primitive.ble.set_characteristics_value

ble_notify_characteristics_value_ gatt new_value:
  #primitive.ble.notify_characteristics_value

ble_get_characteristics_value_ gatt:
  #primitive.ble.get_characteristics_value
