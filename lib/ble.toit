// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor
import uuid
import monitor show ResourceState_
import system
import system show platform
import encoding.hex

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
      data_ = data_.to-ascii-lower
    else:
      throw "TYPE ERROR: data is not a string or byte array"

  stringify -> string:
    if data_ is ByteArray:
      if data_.size <= 4:
        return hex.encode data_
      else:
        return (uuid.Uuid data_).stringify
    else:
      return data_

  to-byte-array:
    if data_ is string:
      if data_.size <= 4: return hex.decode data_
      return (uuid.parse data_).to-byte-array
    else:
      return data_

  encode-for-platform_:
    if ble-platform-requires-uuid-as-byte-array_:
      return to-byte-array
    else:
      return stringify

  hash-code:
    return to-byte-array.hash-code

  operator== other/BleUuid:
    return to-byte-array == other.to-byte-array

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

BLE-CONNECT-MODE-NONE                  ::= 0
BLE-CONNECT-MODE-DIRECTIONAL           ::= 1
BLE-CONNECT-MODE-UNDIRECTIONAL         ::= 2

BLE-ADVERTISE-FLAGS-LIMITED-DISCOVERY  ::= 0x01
BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY  ::= 0x02
BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED  ::= 0x04

BLE-DEFAULT-PREFERRED-MTU_             ::= 23

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
  service-classes/List

  /**
  Advertised manufacturer-specific data.
  */
  manufacturer-data/io.Data

  /**
  Whether connections are allowed.
  */
  connectable/bool

  /**
  Advertise flags. This must be a bitwise 'or' of the BLE_ADVERTISE_FLAG_* constants
    (see $BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY and similar).
  */
  flags/int

  constructor --.name=null --.service-classes=[] --.manufacturer-data=#[]
              --.connectable=false --.flags=0 --check-size=true:
    size := 0
    if name: size += 2 + name.size
    service-classes.do: | uuid/BleUuid |
      size += 2 + uuid.to-byte-array.size
    if manufacturer-data.byte-size > 0: size += 2 + manufacturer-data.byte-size
    if size > 31 and check-size: throw "PACKET_SIZE_EXCEEDED"

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

CHARACTERISTIC-PROPERTY-BROADCAST                    ::= 0x0001
CHARACTERISTIC-PROPERTY-READ                         ::= 0x0002
CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE       ::= 0x0004
CHARACTERISTIC-PROPERTY-WRITE                        ::= 0x0008
CHARACTERISTIC-PROPERTY-NOTIFY                       ::= 0x0010
CHARACTERISTIC-PROPERTY-INDICATE                     ::= 0x0020
CHARACTERISTIC-PROPERTY-AUTHENTICATED-SIGNED-WRITES  ::= 0x0040
CHARACTERISTIC-PROPERTY-NOTIFY-ENCRYPTION-REQUIRED   ::= 0x0100
CHARACTERISTIC-PROPERTY-INDICATE-ENCRYPTION-REQUIRED ::= 0x0200

CHARACTERISTIC-PERMISSION-READ                       ::= 0x01
CHARACTERISTIC-PERMISSION-WRITE                      ::= 0x02
CHARACTERISTIC-PERMISSION-READ-ENCRYPTED             ::= 0x04
CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED            ::= 0x08

class RemoteDescriptor extends RemoteReadWriteElement_ implements Attribute:
  characteristic/RemoteCharacteristic
  uuid/BleUuid

  constructor.private_ .characteristic .uuid descriptor:
    super characteristic.service descriptor

  /**
  Closes this descriptor.

  Automatically removes the descriptor from the list of discovered descriptors of
    the characteristic.
  */
  close_ -> none:
    characteristic.remove-descriptor_ this
    super

  /**
  Reads the value of the descriptor on the remote device.
  */
  read -> ByteArray?:
    return request-read_

  /**
  Writes the value of the descriptor on the remote device.

  Throws if the $value is greater than the negotiated mtu (see $Adapter.set-preferred-mtu,
    $RemoteCharacteristic.mtu, and $RemoteDevice.mtu).
  */
  write value/io.Data -> none:
    write_ value --expects-response=false --no-flush

  /**
  The handle of the descriptor.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  handle -> int:
    return ble-handle_ resource_

/**
A remote characteristic belonging to a remote service.
*/
class RemoteCharacteristic extends RemoteReadWriteElement_ implements Attribute:
  service/RemoteService
  uuid/BleUuid
  properties/int
  discovered-descriptors_/List := []

  constructor.private_ .service .uuid .properties characteristic:
    super service characteristic

  /**
  The list of discovered descriptors on the remote characteristic.

  Call $discover-descriptors to populate this list.
  */
  discovered-descriptors -> List:
    return discovered-descriptors_.copy

  /**
  Closes this characteristic.

  Automatically removes the characteristic from the list of discovered characteristics of
    the service.
  */
  close_ -> none:
    descriptors := discovered-descriptors_
    discovered-descriptors_ = []
    descriptors.do: | descriptor/RemoteDescriptor | descriptor.close_
    service.remove-characteristic_ this
    super

  /**
  Reads the value of the characteristic on the remote device.
  */
  read -> ByteArray?:
    if properties & CHARACTERISTIC-PROPERTY-READ == 0:
      throw "Characteristic does not support reads"

    return request-read_

  /**
  Waits until the remote device sends a notification or indication on the characteristics. Returns the
    notified/indicated value.
  See $subscribe.
  */
  wait-for-notification -> ByteArray?:
    if properties & (CHARACTERISTIC-PROPERTY-INDICATE | CHARACTERISTIC-PROPERTY-NOTIFY) == 0:
      throw "Characteristic does not support notifications or indications"

    while true:
      resource-state_.clear-state VALUE-DATA-READY-EVENT_
      buf := ble-get-value_ resource_
      if buf: return buf
      state := resource-state_.wait-for-state VALUE-DATA-READY-EVENT_ | VALUE-DATA-READ-FAILED-EVENT_ | DISCONNECTED-EVENT_
      if state & VALUE-DATA-READ-FAILED-EVENT_ != 0: throw-error_
      if state & DISCONNECTED-EVENT_ != 0: throw "Disconnected"

  /**
  Writes the value of the characteristic on the remote device.

  If $flush is true, waits until the data has been written. If the characteristic
    requires a response, then this flag is ignored and the function always
    waits for the response.
  */
  write value/io.Data --flush/bool=false -> none:
    if (properties & (CHARACTERISTIC-PROPERTY-WRITE
                      | CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE)) == 0:
      throw "Characteristic does not support write"

    expects-response := (properties & CHARACTERISTIC-PROPERTY-WRITE) != 0
    write_ value --expects-response=expects-response --flush=flush

  /**
  Requests to subscribe on this characteristic.

  This will either enable notifications or indications depending on $properties. If both, indications
    and notifications, are enabled, subscribes to notifications.
  */
  subscribe -> none:
    set-notify-subscription_ --subscribe=true

  /**
  Unsubscribes from a notification or indications on the characteristics.
    See $subscribe.
  */
  unsubscribe -> none:
    set-notify-subscription_ --subscribe=false

  set-notify-subscription_ --subscribe/bool -> none:
    if (properties & (CHARACTERISTIC-PROPERTY-INDICATE
                    | CHARACTERISTIC-PROPERTY-NOTIFY)) == 0:
      throw "Characteristic does not support notification or indication"
    resource-state_.clear-state  SUBSCRIPTION-OPERATION-FAILED_
    ble-set-characteristic-notify_ resource_ subscribe
    state := resource-state_.wait-for-state SUBSCRIPTION-OPERATION-SUCCEEDED_ | SUBSCRIPTION-OPERATION-FAILED_
    if state & SUBSCRIPTION-OPERATION-FAILED_ != 0:
      throw-error_

  /**
  Discovers all descriptors for this characteristic.

  This method adds all discovered descriptors to the list of discovered descriptors of the
    characteristic, regardless of whether a descriptor with the same UUID already exists in the list.
  */
  discover-descriptors -> List:
    resource-state_.clear-state DESCRIPTORS-DISCOVERED-EVENT_
    ble-discover-descriptors_ resource_
    state := wait-for-state-with-oom_ DESCRIPTORS-DISCOVERED-EVENT_
                                   | DISCONNECTED-EVENT_
                                   | DISCOVERY-OPERATION-FAILED_
    if state & DISCONNECTED-EVENT_ != 0:
      throw "BLE disconnected"
    else if state & DISCOVERY-OPERATION-FAILED_ != 0:
      throw-error_

    discovered-descriptors_.add-all
        List.from
            (ble-discover-descriptors-result_ resource_).map:
                RemoteDescriptor.private_ this (BleUuid it[0]) it[1]

    return discovered-descriptors_

  /**
  Removes the given $remote-descriptor from the list of discovered descriptors.
  */
  remove-descriptor_ remote-descriptor/RemoteDescriptor -> none:
    discovered-descriptors_.remove remote-descriptor

  /**
  The negotiated mtu on the characteristics.
  On MacOS this is the maximum payload.
  On ESP32 this is the raw mtu value. Three of these bytes are needed for the header, and
    the maximum payload on ESP32 is thus three bytes smaller than this value.
  */
  mtu -> int:
    return ble-get-att-mtu_ resource_

  /**
  The handle of the characteristic.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  handle -> int:
    return ble-handle_ resource_


/**
A service connected to a remote device through a client.
*/
class RemoteService extends Resource_ implements Attribute:
  /** The ID of the remote service. */
  uuid/BleUuid

  device/RemoteDevice

  discovered-characteristics/List := []

  constructor.private_ .device .uuid service-resource:
    super service-resource

  /**
  Closes this service.

  Automatically removes the service from the list of discovered services of the device.
  */
  close_ -> none:
    characteristics := discovered-characteristics
    discovered-characteristics = []
    characteristics.do: | characteristic/RemoteCharacteristic | characteristic.close_
    device.remove-service_ this
    super

  /**
  Discovers characteristics on the remote service by looking up the handle of the given $characteristic-uuids.

  If $characteristic-uuids is not given or empty all characteristics for the service are discovered.

  Note: Some platforms only support an empty list or a list of size 1. If the platform is limited, this method
    throws.

  This method adds all discovered characteristics to the list of discovered
    characteristics of the service, regardless of whether a characteristic with the same UUID
    already exists in the list.
  */
  // TODO(florian): only add the characteristics that are not already in the list.
  discover-characteristics characteristic-uuids/List=[] -> List:
    resource-state_.clear-state CHARACTERISTIS-DISCOVERED-EVENT_
    raw-characteristics-uuids := characteristic-uuids.map: | uuid/BleUuid | uuid.encode-for-platform_
    ble-discover-characteristics_ resource_ (Array_.ensure raw-characteristics-uuids)
    state := wait-for-state-with-oom_ CHARACTERISTIS-DISCOVERED-EVENT_
                                   | DISCONNECTED-EVENT_
                                   | DISCOVERY-OPERATION-FAILED_
    if state & DISCONNECTED-EVENT_ != 0:
      throw "BLE disconnected"
    else if state & DISCOVERY-OPERATION-FAILED_ != 0:
      throw-error_

    discovered-characteristics.add-all
        List.from
            (ble-discover-characteristics-result_ resource_).map:
              RemoteCharacteristic.private_ this (BleUuid it[0]) it[1] it[2]

    return order-attributes_ characteristic-uuids discovered-characteristics

  /**
  Removes the given $remote-characteristic from the list of discovered characteristics.
  */
  remove-characteristic_ remote-characteristic/RemoteCharacteristic -> none:
    discovered-characteristics.remove remote-characteristic

/**
A remote connected device.
*/
class RemoteDevice extends Resource_:
  /**
  The manager that is responsible for the connection.
  */
  manager/Central

  /**
  The address of the remote device the client is connected to.

  The type of the address is platform dependent.
  */
  address/any

  discovered-services_/List := []

  constructor.private_ .manager .address secure/bool:
    device-resource := ble-connect_ manager.resource_ address secure
    super device-resource
    state := resource-state_.wait-for-state CONNECTED-EVENT_ | CONNECT-FAILED-EVENT_
    if state & CONNECT-FAILED-EVENT_ != 0:
      close_
      throw "BLE connection failed"

  /**
  Removes the given $remote-service from the list of discovered services.
  */
  remove-service_ remote-service/RemoteService -> none:
    discovered-services_.remove remote-service

  /**
  The list of discovered services on the remote device.

  Call $discover-services to populate this list.
  */
  discovered-services -> List:
    return discovered-services_.copy

  /**
  Discovers remote services by looking up the given $service-uuids on the remote device.

  If $service-uuids is empty all services for the device are discovered.

  This method adds all discovered services to the list of discovered services of the device,
    regardless of whether a service with the same UUID already exists in the list.

  Note: Some platforms, like the ESP32, only support an empty list (the default) or a list
    of size 1. If the platform is limited, this method throws for lists with more than
    one element.
  */
  discover-services service-uuids/List=[] -> List:
    resource-state_.clear-state SERVICES-DISCOVERED-EVENT_
    raw-service-uuids := service-uuids.map: | uuid/BleUuid | uuid.encode-for-platform_
    ble-discover-services_ resource_ (Array_.ensure raw-service-uuids)
    state := wait-for-state-with-oom_ SERVICES-DISCOVERED-EVENT_
                                   | DISCONNECTED-EVENT_
                                   | DISCOVERY-OPERATION-FAILED_
    if state & DISCONNECTED-EVENT_ != 0:
      throw "BLE disconnected"
    else if state & DISCOVERY-OPERATION-FAILED_ != 0:
      throw-error_

    discovered-services_.add-all
        (ble-discover-services-result_ resource_).map:
          RemoteService.private_ this (BleUuid it[0]) it[1]

    return order-attributes_ service-uuids discovered-services_

  /**
  Disconnects from the remote device.

  If $force is true, the connection is closed immediately. Otherwise, the
    method waits until the remote device has acknowledged the disconnection.
  */
  close --force/bool=false -> none:
    services := discovered-services_
    discovered-services_ = []
    services.do: | service/RemoteService | service.close_
    ble-disconnect_ resource_
    if not force:
      resource-state_.wait-for-state DISCONNECTED-EVENT_
    manager.remove-device_ this
    close_

  mtu -> int:
    return ble-get-att-mtu_ resource_

/**
Defines a BLE service with characteristics.
*/
class LocalService extends Resource_ implements Attribute:
  static DEFAULT-READ-TIMEOUT-MS ::= 2500

  /**
  The UUID of the service.
  */
  uuid/BleUuid

  peripheral-manager/Peripheral

  deployed_/bool := false

  characteristics_/List := []

  constructor .peripheral-manager .uuid:
    if peripheral-manager.deployed_: throw "Peripheral is already deployed"
    if (peripheral-manager.services_.any: it.uuid == uuid): throw "Service already exists"
    resource := ble-add-service_ peripheral-manager.resource_ uuid.encode-for-platform_
    super resource

  /**
  Closes this service and all its characteristics.
  */
  close_ -> none:
    characteristics := characteristics_
    characteristics_ = []
    characteristics.do: | characteristic/LocalCharacteristic | characteristic.close_
    peripheral-manager.remove-service_ this
    super

  /**
  Removes the given $characteristic from the list of characteristics.
  */
  remove-characteristic_ characteristic/LocalCharacteristic -> none:
    characteristics_.remove characteristic

  /**
  Adds a characteristic to this service with the given parameters.

  The $uuid is the uuid of the characteristic
  The $properties is one of the CHARACTERISTIC_PROPERTY_* values (see
    $CHARACTERISTIC-PROPERTY-BROADCAST and similar).
  $permissions is one of the CHARACTERISTIC_PERMISSIONS_* values (see
    $CHARACTERISTIC-PERMISSION-READ and similar).

  If $value is specified and the characteristic supports reads, it is used as the initial
    value for the characteristic. If $value is null or an empty ByteArray, then the
    characteristic supports callback reads and the client needs
    to call $LocalCharacteristic.handle-read-request to provide the value upon request.
  NOTE: Read callbacks are not supported in MacOS.
  When using read callbacks, the $read-timeout-ms specifies the time the callback function is allowed
    to use.
  The peripheral must not yet be deployed.

  See $add-indication-characteristic, $add-notification-characteristic, $add-read-only-characteristic,
    and $add-write-only-characteristic for convenience methods.
  */
  add-characteristic -> LocalCharacteristic
      uuid/BleUuid
      --properties/int
      --permissions/int
      --value/io.Data?=null
      --read-timeout-ms/int=DEFAULT-READ-TIMEOUT-MS:
    if peripheral-manager.deployed_: throw "Service is already deployed"
    read-permission-bits := CHARACTERISTIC-PERMISSION-READ
        | CHARACTERISTIC-PERMISSION-READ-ENCRYPTED
    read-properties-bits := CHARACTERISTIC-PROPERTY-READ
        | CHARACTERISTIC-PROPERTY-NOTIFY
        | CHARACTERISTIC-PROPERTY-INDICATE
    write-permission-bits := CHARACTERISTIC-PERMISSION-WRITE
        | CHARACTERISTIC-PERMISSION-WRITE-ENCRYPTED
    write-properties-bits := CHARACTERISTIC-PROPERTY-WRITE
        | CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE

    if permissions & read-permission-bits != 0 and
        properties & read-properties-bits == 0:
      throw "Read permission requires read property (READ, NOTIFY or INDICATE)"
    if permissions & write-permission-bits != 0 and
        properties & write-properties-bits == 0:
      throw "Write permission requires write property (WRITE or WRITE_WITHOUT_RESPONSE)"

    characteristic := LocalCharacteristic this uuid properties permissions value read-timeout-ms
    characteristics_.add characteristic
    return characteristic

  /**
  Convenience method to add a read-only characteristic with the given $uuid and $value.

  If $value is specified, it is used as the initial value for the characteristic. If $value is null
    or an empty ByteArray, then the characteristic supports callback reads and the client needs
    to call $LocalCharacteristic.handle-read-request to provide the value upon request.
  NOTE: Read callbacks are not supported in MacOS.
  When using read callbacks, the $read-timeout-ms specifies the time the callback function is allowed
    to use.

  See $add-characteristic.
  */
  add-read-only-characteristic -> LocalCharacteristic
      uuid/BleUuid
      --value/io.Data?
      --read-timeout-ms/int=DEFAULT-READ-TIMEOUT-MS:
    return add-characteristic
        uuid
        --properties=CHARACTERISTIC-PROPERTY-READ
        --permissions=CHARACTERISTIC-PERMISSION-READ
        --value=value

  /**
  Convenience method to add a write-only characteristic with the given $uuid.

  If $requires-response is true, the client must acknowledge the write operation. Any
    $RemoteCharacteristic.write operation will block until the client acknowledges the write.
    The acknowledgment is frequently done by the BLE stack. An acknowledgment thus
    does not necessarily mean that the write operation has been processed by the client.

  See $add-characteristic.

  Deprecated. Use $(add-write-only-characteristic uuid --requires-response) instead.
  */
  add-write-only-characteristic uuid/BleUuid requires-response/bool -> LocalCharacteristic:
    return add-write-only-characteristic uuid --requires-response=requires-response

  /**
  Convenience method to add a write-only characteristic with the given $uuid.

  If $requires-response is true, the client must acknowledge the write operation. Any
    $RemoteCharacteristic.write operation will block until the client acknowledges the write.
    The acknowledgment is frequently done by the BLE stack. An acknowledgment thus
    does not necessarily mean that the write operation has been processed by the client.

  See $add-characteristic.
  */
  add-write-only-characteristic uuid/BleUuid --requires-response/bool=false -> LocalCharacteristic:
    properties := requires-response
      ? CHARACTERISTIC-PROPERTY-WRITE
      : CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE
    return add-characteristic
        uuid
        --properties=properties
        --permissions=CHARACTERISTIC-PERMISSION-WRITE

  /**
  Convenience method to add a notification characteristic with the given $uuid.

  Contrary to indications ($add-indication-characteristic), notifications do not require
    an acknowledgment from the client.

  See $add-characteristic.
  */
  add-notification-characteristic uuid/BleUuid -> LocalCharacteristic:
    return add-characteristic
        uuid
        --properties=CHARACTERISTIC-PROPERTY-NOTIFY | CHARACTERISTIC-PROPERTY-READ
        --permissions=CHARACTERISTIC-PERMISSION-READ

  /**
  Convenience method to add an indication characteristic with the given $uuid.

  Contrary to notifications ($add-notification-characteristic), indications require
    an acknowledgment from the client.

  See $add-characteristic.
  */
  add-indication-characteristic uuid/BleUuid  -> LocalCharacteristic:
    return add-characteristic
        uuid
        --properties=CHARACTERISTIC-PROPERTY-INDICATE | CHARACTERISTIC-PROPERTY-READ
        --permissions=CHARACTERISTIC-PERMISSION-READ

  /**
  Deploys this service.

  After deployment, no more characteristics can be added.

  See $add-characteristic.

  Deprecated. Use $Peripheral.deploy instead.
  */
  deploy -> none:
    peripheral-manager.deploy

  /**
  Deploys the service.
  Depending on the platform, the peripheral manager may still need to start the gatt server.
  */
  deploy_ index/int -> none:
    ble-deploy-service_ resource_ index
    state := resource-state_.wait-for-state (SERVICE-ADD-SUCCEEDED-EVENT_ | SERVICE-ADD-FAILED-EVENT_)
    if state & SERVICE-ADD-FAILED-EVENT_ != 0: throw "Failed to add service"

class LocalCharacteristic extends LocalReadWriteElement_ implements Attribute:
  uuid/BleUuid

  permissions/int
  properties/int
  service/LocalService

  descriptors_/List := []
  read-timeout-ms_/int

  constructor .service .uuid .properties .permissions value/io.Data? .read-timeout-ms_:
    if service.peripheral-manager.deployed: throw "Peripheral is already deployed"
    if (service.characteristics_.any: it.uuid == uuid): throw "Characteristic already exists"
    resource := ble-add-characteristic_ service.resource_ uuid.encode-for-platform_ properties permissions value
    super resource

  /**
  Close this characteristic and all its descriptors.
  */
  close_ -> none:
    descriptors := descriptors_
    descriptors_ = []
    descriptors.do: | descriptor/LocalDescriptor | descriptor.close_
    service.remove-characteristic_ this
    super

  /**
  Removes the given $local-descriptor from the list of descriptors.
  */
  remove-descriptor_ local-descriptor/LocalDescriptor -> none:
    descriptors_.remove local-descriptor

  /**
  Sends a notification or an indication, based on the properties of the characteristic.

  If the characteristic supports both indications and notifications, then a notification is sent.
  */
  write value/io.Data:
    if permissions & CHARACTERISTIC-PERMISSION-READ == 0: throw "Invalid permission"

    if (properties & (CHARACTERISTIC-PROPERTY-NOTIFY | CHARACTERISTIC-PROPERTY-INDICATE)) != 0:
      clients := ble-get-subscribed-clients resource_
      clients.do:
        ble-notify-characteristics-value_ resource_ it value
    else:
      ble-set-value_ resource_ value

  /**
  Reads a value that is written to this characteristic.

  Waits until a client writes a value.
  */
  read -> ByteArray:
    if (permissions & CHARACTERISTIC-PERMISSION-WRITE) == 0:
      throw "Invalid permission"
    return read_

  /**
  Handles read requests.

  This blocking function waits for read requests on this characteristic and calls the
    given $block for each request.
  The block must return an $io.Data which is then used as value of the characteristic.
  */
  handle-read-request [block]:
    for-read ::= true
    resource-state_.clear-state DATA-READ-REQUEST-EVENT_
    ble-callback-init_ resource_ read-timeout-ms_ for-read
    try:
      while true:
        resource-state_.wait-for-state DATA-READ-REQUEST-EVENT_
        if not resource_: return
        value := block.call
        resource-state_.clear-state DATA-READ-REQUEST-EVENT_
        ble-callback-reply_ resource_ value for-read
    finally:
      // If the resource is already gone, then the corresponding callback data-structure
      // is already deallocated as well.
      if resource_: ble-callback-deinit_ resource_ for-read

  /**
  Adds a descriptor to this characteristic.
  $uuid is the uuid of the descriptor
  $properties is one of the CHARACTERISTIC_PROPERTY_* values (see
    $CHARACTERISTIC-PROPERTY-BROADCAST and similar).
  $permissions is one of the CHARACTERISTIC_PERMISSIONS_* values (see
    $CHARACTERISTIC-PERMISSION-READ and similar).
  if $value is specified, it is used as the initial value for the characteristic.
  The peripheral must not yet be deployed.
  */
  add-descriptor uuid/BleUuid properties/int permissions/int value/io.Data?=null -> LocalDescriptor:
    return LocalDescriptor this uuid properties permissions value

  /**
  The handle of the characteristic.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  handle -> int:
    return ble-handle_ resource_


class LocalDescriptor extends LocalReadWriteElement_ implements Attribute:
  uuid/BleUuid
  characteristic/LocalCharacteristic
  permissions/int
  properties/int

  constructor .characteristic .uuid .properties .permissions value/io.Data:
    service := characteristic.service
    if service.peripheral-manager.deployed: throw "Peripheral is already deployed"
    if (characteristic.descriptors_.any: it.uuid == uuid): throw "Descriptor already exists"
    resource :=  ble-add-descriptor_ characteristic.resource_ uuid.encode-for-platform_ properties permissions value
    super resource

  /**
  Closes this descriptor.
  */
  close_ -> none:
    characteristic.remove-descriptor_ this
    super

  write value/io.Data:
    if (permissions & CHARACTERISTIC-PERMISSION-WRITE) == 0:
      throw "Invalid permission"
    ble-set-value_ resource_ value

  read -> ByteArray:
    if (permissions & CHARACTERISTIC-PERMISSION-WRITE) == 0:
      throw "Invalid permission"
    return read_

  /**
  The handle of the descriptor.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  handle -> int:
    return ble-handle_ resource_

/**
The manager for creating client connections.
*/
class Central extends Resource_:
  adapter/Adapter

  remotes-devices_/List := []

  constructor .adapter:
    super (ble-create-central-manager_ adapter.resource_)

  close:
    remotes := remotes-devices_
    remotes-devices_ = []
    remotes.do: | remote-device/RemoteDevice | remote-device.close
    adapter.remove-central_ this
    close_

  /**
  Connects to the remote device with the given $address.

  Connections cannot be established while a scan is ongoing.

  If $secure is true, the connections is secured and the remote
    peer is bonded.
  */
  connect address/any --secure/bool=false -> RemoteDevice:
    remote-device := RemoteDevice.private_ this address secure
    remotes-devices_.add remote-device
    return remote-device

  /**
  Removes the given $remote-device from the list of connected devices.
  */
  remove-device_ remote-device/RemoteDevice -> none:
    remotes-devices_.remove remote-device

  /**
  Scans for nearby devices. This method blocks while the scan is ongoing.

  Only one scan can run at a time.

  Connections cannot be established while a scan is ongoing.

  Stops the scan after the given $duration.
  */
  scan [block] --duration/Duration?=null:
    duration-us := duration ? (max 0 duration.in-us) : -1
    resource-state_.clear-state COMPLETED-EVENT_
    ble-scan-start_ resource_ duration-us
    try:
      while true:
        state := wait-for-state-with-oom_ DISCOVERY-EVENT_ | COMPLETED-EVENT_
        next := ble-scan-next_ resource_
        if not next:
          resource-state_.clear-state DISCOVERY-EVENT_
          if state & COMPLETED-EVENT_ != 0: return
          continue

        service-classes := []
        raw-service-classes := next[3]
        if raw-service-classes:
          raw-service-classes.size.repeat:
            service-classes.add
                BleUuid raw-service-classes[it]

        discovery := RemoteScannedDevice
          next[0]
          next[1]
          AdvertisementData
            --name=next[2]
            --service-classes=service-classes
            --manufacturer-data=(next[4]?next[4]:#[])
            --flags=next[5]
            --connectable=next[6]
            --check-size=false
        block.call discovery
    finally:
      ble-scan-stop_ resource_
      resource-state_.wait-for-state COMPLETED-EVENT_

  /**
  Returns a list of device addresses that have been bonded. The elements
    of the list can be used as arguments to $connect.

  NOTE: Not implemented on MacOS.
  */
  bonded-peers -> List:
    return List.from (ble-get-bonded-peers_ resource_)

/**
The manager for advertising and managing local services.
*/
class Peripheral extends Resource_:
  static DEFAULT-INTERVAL ::= Duration --us=46875
  adapter/Adapter

  services_/List := []

  deployed_/bool := false

  constructor .adapter bonding/bool secure-connections/bool:
    resource := ble-create-peripheral-manager_ adapter.resource_ bonding secure-connections
    super resource

  /**
  Closes the peripheral manager and all its services.
  */
  close:
    if is-closed: return
    stop-advertise
    services := services_
    services_ = []
    services.do: | service/LocalService | service.close_
    adapter.remove-peripheral_ this
    close_

  /**
  Removes the given $local-service from the list of deployed services.
  */
  remove-service_ local-service/LocalService -> none:
    services_.remove local-service

  /**
  Starts advertising the $data.

  The data is advertised once every $interval.

  The advertise includes the given $connection-mode, which must be one
    of the BLE_CONNECT_MODE_* constants (see $BLE-CONNECT-MODE-NONE and similar).

  Throws, If the adapter does not support parts of the advertise content.
  For example, on MacOS manufacturing data can not be specified.

  Throws, If the adapter does not allow configuration of $interval or $connection-mode.
  */
  start-advertise
      data/AdvertisementData
      --interval/Duration=DEFAULT-INTERVAL
      --connection-mode/int=BLE-CONNECT-MODE-NONE:
    if platform == system.PLATFORM-MACOS:
      if interval != DEFAULT-INTERVAL or connection-mode != BLE-CONNECT-MODE-NONE: throw "INVALID_ARGUMENT"

    raw-service-classes := Array_ data.service-classes.size null

    data.service-classes.size.repeat:
      id/BleUuid := data.service-classes[it]
      raw-service-classes[it] = id.encode-for-platform_
    ble-advertise-start_
        resource_
        data.name or ""
        raw-service-classes
        data.manufacturer-data
        interval.in-us
        connection-mode
        data.flags

    state := resource-state_.wait-for-state ADVERTISE-START-SUCEEDED-EVENT_ | ADVERTISE-START-FAILED-EVENT_
    if state & ADVERTISE-START-FAILED-EVENT_ != 0: throw "Failed to start advertising"

  /**
  Stops advertising.
  */
  stop-advertise:
    ble-advertise-stop_ resource_

  /**
  Adds a new service to the peripheral identified by $uuid. The returned service should be configured with
    the appropriate characteristics and then be deployed.
  */
  add-service uuid/BleUuid -> LocalService:
    service := LocalService this uuid
    services_.add service
    return service

  /**
  Whether the peripheral's services have been deployed.
  */
  deployed -> bool:
    return deployed_

  /**
  Deploys all services of the peripheral.

  After deployment, no more services or characteristics can be added.
  */
  deploy -> none:
    if deployed_: throw "Already deployed"
    ble-reserve-services_ resource_ services_.size
    services_.size.repeat: | i/int |
      service/LocalService := services_[i]
      service.deploy_ i
    ble-start-gatt-server_ resource_
    deployed_ = true

class AdapterConfig:
  /**
  Whether support for bonding is enabled.
  */
  bonding/bool

  /**
  Whether support for secure connections is enabled.
  */
  secure-connections/bool

  constructor
      --.bonding/bool=false
      --.secure-connections/bool=false:


class AdapterMetadata:
  identifier/string
  address/ByteArray
  supports-central-role/bool
  supports-peripheral-role/bool
  handle_/any

  constructor.private_ .identifier .address .supports-central-role .supports-peripheral-role .handle_:

  adapter -> Adapter:
    return Adapter.private_ this

/**
An adapter represents the chip or peripheral that is used to communicate over BLE.
On the ESP32 it is the integrated peripheral. On desktops it is provided by
  the operating system, and can be a USB chip, or an integrated chip of laptops.
*/
class Adapter extends Resource_:
  static discover-adapter-metadata_ -> List/*<AdapterMetadata>*/:
    return ble-retrieve-adapters_.map:
      AdapterMetadata.private_ it[0] it[1] it[2] it[3] it[4]

  adapter-metadata/AdapterMetadata?
  central_/Central? := null
  peripheral_/Peripheral? := null

  constructor: return discover-adapter-metadata_[0].adapter

  constructor.private_ .adapter-metadata:
    super (ble-create-adapter_ resource-group_)
    resource-state_.wait-for-state STARTED-EVENT_

  close -> none:
    if is-closed: return
    if central_:
      central_.close
      central_ = null
    if peripheral_:
      peripheral_.close
      peripheral_ = null
    close_

  /**
  The central manager handles connections to remote peripherals.
  It is responsible for scanning, discovering and connecting to other devices.
  */
  central -> Central:
    if not adapter-metadata.supports-central-role: throw "NOT_SUPPORTED"
    if not central_: central_ = Central this
    return central_

  remove-central_ central/Central -> none:
    assert: central == central_
    central_ = null

  /**
  The peripheral manager is used to advertise and publish local services.

  If $bonding is true then the peripheral is allowing remote centrals to bond. In that
    case the information of the pairing process may be stored on the device to make
    reconnects more efficient.

  If $secure-connections the peripheral is enabling secure connections.
  */
  peripheral --bonding/bool=false --secure-connections/bool=false -> Peripheral:
    if not adapter-metadata.supports-peripheral-role: throw "NOT_SUPPORTED"
    if not peripheral_: peripheral_ = Peripheral this bonding secure-connections
    return peripheral_;

  remove-peripheral_ peripheral/Peripheral -> none:
    assert: peripheral == peripheral_
    peripheral_ = null

  set-preferred-mtu mtu/int:
    ble-set-preferred-mtu_ resource_ mtu

// General events
MALLOC-FAILED_                        ::= 1 << 22

// Manager lifecycle events
STARTED-EVENT_                        ::= 1 << 0

// Central Manager Events
COMPLETED-EVENT_                      ::= 1 << 1
DISCOVERY-EVENT_                      ::= 1 << 2
DISCOVERY-OPERATION-FAILED_           ::= 1 << 21

// Remote Device Events
CONNECTED-EVENT_                      ::= 1 << 3
CONNECT-FAILED-EVENT_                 ::= 1 << 4
DISCONNECTED-EVENT_                   ::= 1 << 5
SERVICES-DISCOVERED-EVENT_            ::= 1 << 6
READY-TO-SEND-WITHOUT-RESPONSE-EVENT_ ::= 1 << 13

// Remote Service events
CHARACTERISTIS-DISCOVERED-EVENT_      ::= 1 << 7

// Remote Characteristics events
VALUE-DATA-READY-EVENT_               ::= 1 << 9
VALUE-DATA-READ-FAILED-EVENT_         ::= 1 << 10
DESCRIPTORS-DISCOVERED-EVENT_         ::= 1 << 8
VALUE-WRITE-SUCCEEDED-EVENT_          ::= 1 << 11
VALUE-WRITE-FAILED-EVENT_             ::= 1 << 12
SUBSCRIPTION-OPERATION-SUCCEEDED_     ::= 1 << 14
SUBSCRIPTION-OPERATION-FAILED_        ::= 1 << 15

// Peripheral Manager events
ADVERTISE-START-SUCEEDED-EVENT_       ::= 1 << 16
ADVERTISE-START-FAILED-EVENT_         ::= 1 << 17
SERVICE-ADD-SUCCEEDED-EVENT_          ::= 1 << 18
SERVICE-ADD-FAILED-EVENT_             ::= 1 << 19
DATA-RECEIVED-EVENT_                  ::= 1 << 20
DATA-READ-REQUEST-EVENT_              ::= 1 << 23


order-attributes_ input/List/*<BleUUID>*/ output/List/*<Attribute>*/ -> List:
  map := {:}
  if input.is-empty: return output
  output.do: | attribute/Attribute | map[attribute.uuid] = attribute
  // Input might contain Uuids that where never discovered, so make sure to use
  // the non-throwing version of map.get.
  return input.map: | uuid/BleUuid | map.get uuid

class Resource_:
  resource_/any? := null
  resource-state_/ResourceState_

  constructor .resource_:
    resource-state_ = ResourceState_ resource-group_ resource_
    add-finalizer this::
      close_

  close_:
    if resource_:
      try:
        resource := resource_
        resource_ = null
        resource-state_.dispose
        ble-release-resource_ resource
      finally:
        remove-finalizer this

  is-closed -> bool:
    return resource_ == null

  throw-error_ --is-oom/bool=false:
    try:
      ble-get-error_ resource_ is-oom
    finally:
      ble-clear-error_ resource_ is-oom

  wait-for-state-with-oom_ bits -> int:
    state := resource-state_.wait-for-state bits | MALLOC-FAILED_
    if state & MALLOC-FAILED_ == 0: return state
    // We encountered an OOM.
    resource-state_.clear-state MALLOC-FAILED_
    // Use 'throw-error_' to throw the error and clear it from the resource.
    throw-error_ --is-oom
    unreachable

class RemoteReadWriteElement_ extends Resource_:
  remote-service_/RemoteService

  constructor .remote-service_ resource:
    super resource

  write_ value/io.Data --expects-response/bool --flush/bool:
    while true:
      remote-service_.device.resource-state_.clear-state READY-TO-SEND-WITHOUT-RESPONSE-EVENT_
      resource-state_.clear-state VALUE-WRITE-FAILED-EVENT_ | VALUE-WRITE-SUCCEEDED-EVENT_
      result := ble-write-value_ resource_ value expects-response flush
      if result == 0:
        return // Write without response success.
      if result == 1: // Write with response.
        state := resource-state_.wait-for-state VALUE-WRITE-FAILED-EVENT_ | VALUE-WRITE-SUCCEEDED-EVENT_
        if state & VALUE-WRITE-FAILED-EVENT_ != 0: throw-error_
        return
      if result == 2: // Write without response, needs to wait for device ready.
        remote-service_.device.resource-state_.wait-for-state READY-TO-SEND-WITHOUT-RESPONSE-EVENT_

  request-read_ -> ByteArray:
    resource-state_.clear-state VALUE-DATA-READY-EVENT_
    ble-request-read_ resource_
    state := resource-state_.wait-for-state VALUE-DATA-READY-EVENT_ | VALUE-DATA-READ-FAILED-EVENT_
    if state & VALUE-DATA-READ-FAILED-EVENT_ != 0: throw-error_
    return ble-get-value_ resource_


class LocalReadWriteElement_ extends Resource_:
  constructor resource:
    super resource

  read_ -> ByteArray:
    resource-state_.clear-state DATA-RECEIVED-EVENT_
    while true:
      buf := ble-get-value_ resource_
      if buf: return buf
      resource-state_.wait-for-state DATA-RECEIVED-EVENT_

ble-retrieve-adapters_:
  if platform == system.PLATFORM-FREERTOS or platform == system.PLATFORM-MACOS:
    return [["default", #[], true, true, null]]
  throw "Unsupported platform"

resource-group_ := ble-init_

ble-init_:
  #primitive.ble.init

ble-create-adapter_ resource-group_:
  #primitive.ble.create-adapter

ble-create-central-manager_ adapter-resource:
  #primitive.ble.create-central-manager

ble-create-peripheral-manager_ adapter-resource bonding secure-connections:
  #primitive.ble.create-peripheral-manager

ble-scan-start_ central-manager duration-us:
  #primitive.ble.scan-start

ble-scan-next_ central-manager:
  #primitive.ble.scan-next

ble-scan-stop_ central-manager:
  #primitive.ble.scan-stop

ble-connect_ central-manager address secure:
  #primitive.ble.connect

ble-disconnect_ device:
  #primitive.ble.disconnect

ble-release-resource_ resource:
  #primitive.ble.release-resource

ble-discover-services_ device service-uuids:
  #primitive.ble.discover-services

ble-discover-services-result_ device:
  #primitive.ble.discover-services-result

ble-discover-characteristics_ service characteristics-uuids:
  #primitive.ble.discover-characteristics

ble-discover-characteristics-result_ service:
  #primitive.ble.discover-characteristics-result

ble-discover-descriptors_ characteristic:
  #primitive.ble.discover-descriptors

ble-discover-descriptors-result_ characteristic:
  #primitive.ble.discover-descriptors-result

ble-request-read_ resource:
  #primitive.ble.request-read

ble-get-value_ characteristic:
  #primitive.ble.get-value

ble-write-value_ characteristic value with-response flush:
  return ble-run-with-quota-backoff_: | last-attempt/bool |
    ble-write-value__ characteristic value with-response flush (not last-attempt)

// Note that we need two arguments for 'with-response' and 'flush' as some backends
// handle them differently.
ble-write-value__ characteristic value/io.Data with-response flush allow-retry:
  #primitive.ble.write-value:
    return io.primitive-redo-io-data_ it value: | bytes |
      ble-write-value__ characteristic bytes with-response flush allow-retry

ble-handle_ resource:
  #primitive.ble.handle

ble-set-characteristic-notify_ characteristic value:
  #primitive.ble.set-characteristic-notify

ble-advertise-start_ peripheral-manager name services manufacturer-data interval connection-mode flags:
  #primitive.ble.advertise-start

ble-advertise-stop_ peripheral-manager:
  #primitive.ble.advertise-stop

ble-add-service_ peripheral-manager uuid:
  #primitive.ble.add-service

ble-add-characteristic_ service uuid properties permission value:
  return ble-run-with-quota-backoff_:
    ble-add-characteristic__ service uuid properties permission value
  unreachable

ble-add-characteristic__ service uuid properties permission value:
  #primitive.ble.add-characteristic:
    return io.primitive-redo-io-data_ it value: | bytes |
      ble-add-characteristic__ service uuid properties permission bytes

ble-add-descriptor_ characteristic uuid properties permission value:
  return ble-run-with-quota-backoff_:
    ble-add-descriptor__ characteristic uuid properties permission value

ble-add-descriptor__ characteristic uuid properties permission value:
  #primitive.ble.add-descriptor:
    return io.primitive-redo-io-data_ it value: | bytes |
      ble-add-descriptor__ characteristic uuid properties permission bytes

ble-reserve-services_ peripheral-manager count:
  #primitive.ble.reserve-services

ble-deploy-service_ service index:
  #primitive.ble.deploy-service

ble-start-gatt-server_ peripheral-manager:
  #primitive.ble.start-gatt-server

ble-set-value_ characteristic new-value -> none:
  ble-run-with-quota-backoff_:
    ble-set-value__ characteristic new-value

ble-set-value__ characteristic new-value:
  #primitive.ble.set-value:
    return io.primitive-redo-io-data_ it new-value: | bytes |
      ble-set-value__ characteristic bytes

ble-get-subscribed-clients characteristic:
  #primitive.ble.get-subscribed-clients

ble-notify-characteristics-value_ characteristic client new-value:
  return ble-run-with-quota-backoff_:
    ble-notify-characteristics-value__ characteristic client new-value

ble-notify-characteristics-value__ characteristic client new-value:
  #primitive.ble.notify-characteristics-value:
    return io.primitive-redo-io-data_ it new-value: | bytes |
      ble-notify-characteristics-value__ characteristic client bytes

ble-get-att-mtu_ resource:
  #primitive.ble.get-att-mtu

ble-set-preferred-mtu_ adapter mtu:
  #primitive.ble.set-preferred-mtu

ble-get-error_ characteristic is-oom:
  #primitive.ble.get-error

ble-clear-error_ characteristic is-oom:
  #primitive.ble.clear-error

ble-platform-requires-uuid-as-byte-array_:
  return platform == system.PLATFORM-FREERTOS

ble-callback-init_ resource read-timeout-ms for-read:
  #primitive.ble.toit-callback-init

ble-callback-deinit_ resource for-read:
  #primitive.ble.toit-callback-deinit

ble-callback-reply_ resource value for-read:
  ble-run-with-quota-backoff_ :
    ble-callback-reply__ resource value for-read

ble-callback-reply__ resource value for-read:
  #primitive.ble.toit-callback-reply:
    return io.primitive-redo-io-data_ it value: | bytes |
      ble-callback-reply__ resource bytes for-read

ble-get-bonded-peers_ adapter:
  #primitive.ble.get-bonded-peers

ble-run-with-quota-backoff_ [block]:
  start := Time.monotonic-us
  while true:
    // The last-attempt boolean is a signal to the block that it may abort the operation
    // itself if it has a better error than "QUOTA_EXCEEDED".
    last-attempt := Time.monotonic-us - start + 20 > 2_000_000
    catch --unwind=(: it != "QUOTA_EXCEEDED"): return block.call last-attempt
    sleep --ms=10
    if Time.monotonic-us - start > 2_000_000: throw DEADLINE-EXCEEDED-ERROR
