// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import system

import .ble

/**
The manager for creating client connections.
*/
class Central extends Resource_:
  adapter/Adapter

  remotes-devices_/List := []

  constructor .adapter:
    super (ble-create-central-manager_ adapter.resource_)
    resource-state_.wait-for-state STARTED-EVENT_

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
    remote-device := RemoteDevice.private_ this identifier secure
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
  // Construct a map from identifier to the discovered advertisements.
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
    duration-us := duration ? (max 0 duration.in-us) : -1
    resource-state_.clear-state COMPLETED-EVENT_
    ble-scan-start_ resource_ (not active) duration-us interval window limited-only
    is-macos := system.platform == system.PLATFORM_MACOS
    try:
      while true:
        state := wait-for-state-with-oom_ DISCOVERY-EVENT_ | COMPLETED-EVENT_
        next := ble-scan-next_ resource_
        if not next:
          resource-state_.clear-state DISCOVERY-EVENT_
          if state & COMPLETED-EVENT_ != 0: return
          continue

        discovery/RemoteScannedDevice := ?
        if is-macos:
          service-classes := []
          raw-service-classes := next[3]
          if raw-service-classes:
            raw-service-classes.size.repeat:
              service-classes.add
                  BleUuid raw-service-classes[it]

          identifier := next[0]
          rssi := next[1]
          discovery = RemoteScannedDevice
              identifier
              rssi
              --is-connectable=next[6]
              --is-scan-response=false
              --address-bytes=null
              --address-type=null
              AdvertisementData  // @no-warn
                  --name=next[2]
                  --service-classes=service-classes
                  --manufacturer-data=(next[4] ? next[4] : #[])
                  --flags=next[5]
                  --connectable=next[6]
                  --check-size=false
        else:
          identifier := next[0]
          rssi := next[1]
          discovery = RemoteScannedDevice
              identifier
              rssi
              --is-connectable=next[3]
              --is-scan-response=next[4]
              --address-type=identifier[0]
              --address-bytes=identifier[1..]
              AdvertisementData.raw_ next[2] --connectable=next[3]  // @no-warn

        block.call discovery
    finally:
      ble-scan-stop_ resource_
      resource-state_.wait-for-state COMPLETED-EVENT_

  /**
  Returns a list of device identifiers that have been bonded. The elements
    of the list can be used as arguments to $connect.

  NOTE: Not implemented on MacOS.
  */
  bonded-peers -> List:
    return List.from (ble-get-bonded-peers_ resource_)

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
    write_ value --expects-response=false

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

  Deprecated. Use $identifier instead.
  */
  address -> any: return identifier

  /**
  The identifier of the remote device the client is connected to.

  The type of the identifier is platform dependent.
  */
  identifier/Object

  discovered-services_/List := []

  constructor.private_ .manager .identifier secure/bool:
    device-resource := ble-connect_ manager.resource_ identifier secure
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

order-attributes_ input/List/*<BleUUID>*/ output/List/*<Attribute>*/ -> List:
  map := {:}
  if input.is-empty: return output
  output.do: | attribute/Attribute | map[attribute.uuid] = attribute
  // Input might contain Uuids that where never discovered, so make sure to use
  // the non-throwing version of map.get.
  return input.map: | uuid/BleUuid | map.get uuid

class RemoteReadWriteElement_ extends Resource_:
  remote-service_/RemoteService

  constructor .remote-service_ resource:
    super resource

  write_ value/io.Data --expects-response/bool:
    while true:
      remote-service_.device.resource-state_.clear-state READY-TO-SEND-WITHOUT-RESPONSE-EVENT_
      resource-state_.clear-state VALUE-WRITE-FAILED-EVENT_ | VALUE-WRITE-SUCCEEDED-EVENT_
      result := ble-write-value_ resource_ value expects-response
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
