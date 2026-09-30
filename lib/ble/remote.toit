// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

import .ble

/**
The central side of the `ble` package.

$Central, from $Adapter.central, scans for nearby devices
  ($RemoteScannedDevice) and connects to them; a $RemoteDevice gives access
  to the peer's $RemoteService, $RemoteCharacteristic and $RemoteDescriptor
  attributes. Applications reach these classes through `import ble`; the
  Toit host backend (`ble.host`) subclasses them.
*/

/**
The manager for creating client connections.

The public classes of the central side are abstract; the Toit host backend
  (see `ble.host`) provides the subclasses. Applications only see these
  classes.
*/
abstract class Central extends Resource_:
  adapter/Adapter

  remotes-devices_/List := []

  constructor.host_ .adapter:
    super.host_

  close:
    remotes := remotes-devices_
    remotes-devices_ = []
    remotes.do: | remote-device/RemoteDevice | remote-device.close
    adapter.remove-central_ this
    close_

  /**
  Connects to the remote device with the given $identifier.

  Connections cannot be established while a scan is ongoing.

  If $secure is true, the connections is secured and the remote
    peer is bonded.
  */
  connect identifier/any --secure/bool=false -> RemoteDevice:
    remote-device := connect_ identifier secure
    remotes-devices_.add remote-device
    return remote-device

  abstract connect_ identifier/any secure/bool -> RemoteDevice

  /**
  Removes the given $remote-device from the list of connected devices.
  */
  remove-device_ remote-device/RemoteDevice -> none:
    remotes-devices_.remove remote-device

  /**
  Scans for nearby devices. This method blocks while the scan is ongoing.

  Only one scan can run at a time.

  If $active is true, then we request a scan response from discovered devices.
    Users may need to merge the advertisement data from the scan response with the
    advertisement data from the discovery event. Use
    $RemoteScannedDevice.is-scan-response to distinguish between the two.

  Connections cannot be established while a scan is ongoing.

  Stops the scan after the given $duration.

  The $interval is the time between the start of two consecutive scan windows. It is
    given in units of 0.625 ms. If it is 0, the default value of the system is used.

  The $window is the time the scanner is active during a scan window. It is given in
    units of 0.625 ms. If it is 0, the default value of the system is used. The window
    must be less than or equal to the interval.

  If $limited-only is true, only limited discoverable devices are reported. Devices
    declare during advertising whether they are limited (advertising for a limited
    duration) or general (continuously broadcasting). This flag filters out general
    devices.

  # Merging advertisements
  When $active is true, then there are two calls to the $block for each device. The first
    call is for the discovery event, and the second call is for the scan response event.
    It is up to the user to merge the advertisement data from the two calls.

  A simple way to merge advertisement data is to concatenate the $DataBlock entries of
    the advertisements.

  ```
  discovered-blocks := {:}
  central.scan --duration=(Duration --s=2) --active: | device/RemoteScannedDevice |
    blocks := discovered-blocks.get device.identifier --init=: {}
    blocks.add-all device.data.data-blocks
  discovered-advertisements := discovered-blocks.map: | _ blocks |
    Advertisement blocks.to-list --no-check-size
  ```
  */
  scan -> none
      --interval/int=0
      --window/int=0
      --duration/Duration?=null
      --limited-only/bool=false
      --active/bool=false
      [block]:
    if interval != 0 and not 4 <= interval <= 16384:
      throw "Invalid interval"
    if window != 0 and not 4 <= window <= interval:
      throw "Invalid window"
    scan_ --interval=interval --window=window --duration=duration --limited-only=limited-only
        --active=active:
      block.call it

  abstract scan_ -> none
      --interval/int
      --window/int
      --duration/Duration?
      --limited-only/bool
      --active/bool
      [block]

  /**
  Returns a list of device identifiers that have been bonded. The elements
    of the list can be used as arguments to $connect.

  The list holds the peers the BLE service provider chooses to report; a
    provider may report none.
  */
  abstract bonded-peers -> List

/**
A remote device discovered by a scanning.
*/
class RemoteScannedDevice:
  /**
  A globally fixed address that has been registered with IEEE.
  */
  static ADDRESS-TYPE-PUBLIC := 0
  /**
  A random static address.

  A random address that is not changed for the lifetime of the device.
  */
  static ADDRESS-TYPE-RANDOM := 1
  /**
  A resolvable private address.

  A random address that can be resolved to a public or static
    ($ADDRESS-TYPE-RANDOM) address using a pre-shared key.
  */
  static ADDRESS-TYPE-PUBLIC_IDENTITY := 2
  /**
  A non-resolvable private address.

  An address that changes periodically and cannot be resolved to a public
    or static address.
  */
  static ADDRESS-TYPE-RANDOM_IDENTITY := 3

  /**
  The BLE address of the remote device.

  Deprecated: Use $identifier instead.
  */
  address -> any: return identifier

  /**
  The identifier of the remote device.

  The identifier is platform dependent and must be used to $Central.connect to the device.
  The identifier is guaranteed to have a hash code and can thus be used in a $Set or $Map.
  */
  identifier/Object

  /**
  The address of the remote device.

  Not all platforms support this field.
  */
  address-bytes/ByteArray?

  /**
  The type of the address.

  Not all platforms support this field.

  The type is one of the following:
  - 0: Public: $ADDRESS_TYPE_PUBLIC
  - 1: Random: $ADDRESS_TYPE_RANDOM
  - 2: Public Identity: $ADDRESS_TYPE_PUBLIC_IDENTITY
  - 3: Random Identity: $ADDRESS_TYPE_RANDOM_IDENTITY
  */
  address-type/int?

  /**
  The RSSI measured for the remote device.
  */
  rssi/int

  /**
  The advertisement data received from the remote device.
  */
  data/AdvertisementData

  /**
  Whether connections are allowed.
  */
  is-connectable/bool

  /**
  Whether this information was received in a scan response.
  */
  is-scan-response/bool

  /**
  Constructs a remote device.
  */
  constructor .identifier .rssi .data
      --.is-connectable
      --.is-scan-response
      --.address-bytes
      --.address-type:

  /**
  See $super.
  */
  stringify -> string:
    return "$identifier (rssi: $rssi dBm)"

abstract class RemoteDescriptor extends RemoteReadWriteElement_ implements Attribute:
  characteristic/RemoteCharacteristic
  uuid/BleUuid

  constructor.host_ .characteristic .uuid:
    super.host_ characteristic.service

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
    write_ value --expects-response=false

  /**
  The handle of the descriptor.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  abstract handle -> int

/**
A remote characteristic belonging to a remote service.
*/
abstract class RemoteCharacteristic extends RemoteReadWriteElement_ implements Attribute:
  service/RemoteService
  uuid/BleUuid
  properties/int
  discovered-descriptors_/List := []

  constructor.host_ .service .uuid .properties:
    super.host_ service

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
    return wait-for-notification_

  abstract wait-for-notification_ -> ByteArray?

  /**
  Writes the value of the characteristic on the remote device.

  For characteristics without response, the function returns as soon as
    the data has been delivered to the BLE stack. Shutting down the adapter or
    program too soon afterwards might lead to lost data.
  */
  write value/io.Data -> none:
    if (properties & (CHARACTERISTIC-PROPERTY-WRITE
                      | CHARACTERISTIC-PROPERTY-WRITE-WITHOUT-RESPONSE)) == 0:
      throw "Characteristic does not support write"
    expects-response := (properties & CHARACTERISTIC-PROPERTY-WRITE) != 0
    write_ value --expects-response=expects-response

  /**
  Requests to subscribe on this characteristic.

  This will either enable notifications or indications depending on $properties. If both, indications
    and notifications, are enabled, subscribes to notifications.
  */
  subscribe -> none:
    set-notify-subscription_ --subscribe

  /**
  Unsubscribes from a notification or indications on the characteristics.
    See $subscribe.
  */
  unsubscribe -> none:
    set-notify-subscription_ --no-subscribe

  set-notify-subscription_ --subscribe/bool -> none:
    if (properties & (CHARACTERISTIC-PROPERTY-INDICATE
                    | CHARACTERISTIC-PROPERTY-NOTIFY)) == 0:
      throw "Characteristic does not support notification or indication"
    set-subscription_ subscribe

  abstract set-subscription_ subscribe/bool -> none

  /**
  Discovers all descriptors for this characteristic.

  This method adds all discovered descriptors to the list of discovered descriptors of the
    characteristic, regardless of whether a descriptor with the same UUID already exists in the list.
  */
  discover-descriptors -> List:
    discovered-descriptors_.add-all discover-descriptors_
    return discovered-descriptors_

  abstract discover-descriptors_ -> List

  /**
  Removes the given $remote-descriptor from the list of discovered descriptors.
  */
  remove-descriptor_ remote-descriptor/RemoteDescriptor -> none:
    discovered-descriptors_.remove remote-descriptor

  /**
  The negotiated mtu on the characteristics.

  This is the raw ATT mtu value. Three of these bytes are needed for the
    header, so the maximum payload is three bytes smaller than this value.
  */
  abstract mtu -> int

  /**
  The handle of the characteristic.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  abstract handle -> int

/**
A service connected to a remote device through a client.
*/
abstract class RemoteService extends Resource_ implements Attribute:
  /** The ID of the remote service. */
  uuid/BleUuid

  device/RemoteDevice

  discovered-characteristics/List := []

  constructor.host_ .device .uuid:
    super.host_

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

  This method adds all discovered characteristics to the list of discovered
    characteristics of the service, regardless of whether a characteristic with the same UUID
    already exists in the list.
  */
  discover-characteristics characteristic-uuids/List=[] -> List:
    discovered-characteristics.add-all (discover-characteristics_ characteristic-uuids)
    return order-attributes_ characteristic-uuids discovered-characteristics

  abstract discover-characteristics_ characteristic-uuids/List -> List

  /**
  Removes the given $remote-characteristic from the list of discovered characteristics.
  */
  remove-characteristic_ remote-characteristic/RemoteCharacteristic -> none:
    discovered-characteristics.remove remote-characteristic

/**
A remote connected device.
*/
abstract class RemoteDevice extends Resource_:
  /**
  The manager that is responsible for the connection.
  */
  manager/Central

  /**
  The address of the remote device the client is connected to.

  The type of the address is platform dependent.

  Deprecated. Use $identifier instead.
  */
  address -> any: return identifier

  /**
  The identifier of the remote device the client is connected to.

  The type of the identifier is platform dependent.
  */
  identifier/Object

  discovered-services_/List := []

  constructor.host_ .manager .identifier:
    super.host_

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
  */
  discover-services service-uuids/List=[] -> List:
    discovered-services_.add-all (discover-services_ service-uuids)
    return order-attributes_ service-uuids discovered-services_

  abstract discover-services_ service-uuids/List -> List

  /**
  Disconnects from the remote device.

  If $force is true, the connection is closed immediately. Otherwise, the
    method waits until the remote device has acknowledged the disconnection.
  */
  close --force/bool=false -> none:
    services := discovered-services_
    discovered-services_ = []
    services.do: | service/RemoteService | service.close_
    disconnect_ --force=force
    manager.remove-device_ this
    close_

  abstract disconnect_ --force/bool -> none

  abstract mtu -> int

order-attributes_ input/List/*<BleUUID>*/ output/List/*<Attribute>*/ -> List:
  map := {:}
  if input.is-empty: return output
  output.do: | attribute/Attribute | map[attribute.uuid] = attribute
  return input.map: | uuid/BleUuid | map.get uuid

/** A remote attribute that can be read and written. */
abstract class RemoteReadWriteElement_ extends Resource_:
  remote-service_/RemoteService

  constructor.host_ .remote-service_:
    super.host_

  abstract write_ value/io.Data --expects-response/bool
  abstract request-read_ -> ByteArray
