// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

import .adapter
import .advertisement
import .uuid
import .remote show RemoteCharacteristic  // For Toitdoc.

/**
The peripheral side of the `ble` package.

$Peripheral, from $Adapter.peripheral, publishes this device's
  $LocalService, $LocalCharacteristic and $LocalDescriptor attributes to
  connected centrals and advertises them. Applications reach these classes
  through `import ble`; the Toit host backend (`ble.host`) subclasses them.
*/

/**
The manager for advertising and managing local services.

The public classes of the peripheral side are abstract; the Toit host
  backend (see `ble.host`) provides the subclasses. Applications only see
  these classes.
*/
abstract class Peripheral extends Resource_:
  static DEFAULT-INTERVAL ::= Duration --us=46875

  adapter/Adapter
  services_/List := []
  deployed_/bool := false

  constructor.host_ .adapter:
    super.host_

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
    of the BLE-CONNECT-MODE-* constants (see $BLE-CONNECT-MODE-NONE and similar).

  Throws if the adapter does not support parts of the advertise content, or
    does not allow configuration of $interval or $connection-mode.
  */
  abstract start-advertise
      data/Advertisement
      --scan-response/Advertisement?=null
      --interval/Duration=DEFAULT-INTERVAL
      --connection-mode/int=BLE-CONNECT-MODE-NONE

  /**
  Variant of $(start-advertise data).

  Sets the connection-mode to $BLE-CONNECT-MODE-UNDIRECTIONAL.
  */
  start-advertise
      data/Advertisement
      --scan-response/Advertisement?=null
      --interval/Duration=DEFAULT-INTERVAL
      --allow-connections/True:
    start-advertise data --scan-response=scan-response --interval=interval --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL

  /**
  Stops advertising.
  */
  abstract stop-advertise

  /**
  Adds a new service to the peripheral identified by $uuid.

  The returned service should be configured with the appropriate characteristics and then
    be deployed.
  */
  add-service uuid/BleUuid -> LocalService:
    if deployed_: throw "Peripheral is already deployed"
    service := create-service_ uuid
    services_.add service
    return service

  abstract create-service_ uuid/BleUuid -> LocalService

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
    deploy_
    deployed_ = true

  abstract deploy_ -> none

/**
Defines a BLE service with characteristics.
*/
abstract class LocalService extends Resource_ implements Attribute:
  static DEFAULT-READ-TIMEOUT-MS ::= 2500
  static DEFAULT-WRITE-TIMEOUT-MS ::= 2500

  /**
  The UUID of the service.
  */
  uuid/BleUuid

  peripheral-manager/Peripheral
  deployed_/bool := false
  characteristics_/List := []

  constructor.host_ .peripheral-manager .uuid:
    super.host_

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
  Deprecated. Pass the timeout to the $LocalCharacteristic.handle-read-request function instead.
  */
  add-characteristic -> LocalCharacteristic
      uuid/BleUuid
      --properties/int
      --permissions/int
      --value/io.Data?=null
      --read-timeout-ms/int:
    return add-characteristic_ uuid --properties=properties --permissions=permissions --value=value
        --read-timeout-ms=read-timeout-ms

  /**
  Adds a characteristic to this service with the given parameters.

  The $uuid is the uuid of the characteristic

  The $properties is one of the CHARACTERISTIC-PROPERTY-* values (see
    $CHARACTERISTIC-PROPERTY-BROADCAST and similar).

  $permissions is one of the CHARACTERISTIC-PERMISSIONS-* values (see
    $CHARACTERISTIC-PERMISSION-READ and similar).

  If $value is specified and the characteristic supports reads, it is used as the initial
    value for the characteristic. If $value is null or an empty ByteArray, then the
    characteristic supports callback reads and the client needs
    to call $LocalCharacteristic.handle-read-request to provide the value upon request.

  The peripheral must not yet be deployed.

  See $add-indication-characteristic, $add-notification-characteristic, $add-read-only-characteristic,
    and $add-write-only-characteristic for convenience methods.
  */
  add-characteristic -> LocalCharacteristic
      uuid/BleUuid
      --properties/int
      --permissions/int
      --value/io.Data?=null:
    return add-characteristic_ uuid --properties=properties --permissions=permissions --value=value
        --read-timeout-ms=DEFAULT-READ-TIMEOUT-MS

  add-characteristic_ -> LocalCharacteristic
      uuid/BleUuid
      --properties/int
      --permissions/int
      --value/io.Data?
      --read-timeout-ms/int:
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
    characteristic := create-characteristic_ uuid properties permissions value read-timeout-ms
    characteristics_.add characteristic
    return characteristic

  abstract create-characteristic_ uuid/BleUuid properties/int permissions/int value/io.Data? read-timeout-ms/int -> LocalCharacteristic

  /**
  Convenience method to add a read-only characteristic with the given $uuid and $value.

  If $value is specified, it is used as the initial value for the characteristic. If $value is null
    or an empty ByteArray, then the characteristic supports callback reads and the client needs
    to call $LocalCharacteristic.handle-read-request to provide the value upon request.

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

abstract class LocalCharacteristic extends LocalReadWriteElement_ implements Attribute:
  uuid/BleUuid

  permissions/int
  properties/int
  service/LocalService
  descriptors_/List := []
  read-timeout-ms_/int

  constructor.host_ .service .uuid .properties .permissions .read-timeout-ms_:
    super.host_

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
  Sets the value of the characteristic.

  This value is returned when a client reads the characteristic. The $handle-read-request
    function takes precedence over this value.

  Clears the stored value if the given $value is null.

  In most cases $write is sufficient and easier to use. The main reason to use this function
    is to set a value without sending out any notification.
  */
  abstract set-value value/io.Data?

  /**
  Sets the value of this characteristic and sends a notification or indication if supported.

  If the characteristic supports both indications and notifications, then a notification is sent.

  If $set-value is true (the default), sets the value of the characteristic to $value. Any
    read requests will return this value until the value is changed again. See $set-value
    for setting the value without sending out a notification.

  If the characteristic doesn't support notifications or indications and $set-value is set
    to false, then this function does nothing.
  */
  write value/io.Data --set-value/bool=true:
    if permissions & CHARACTERISTIC-PERMISSION-READ == 0: throw "Invalid permission"
    write_ value --set-value=set-value

  abstract write_ value/io.Data --set-value/bool

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

  If no request-handler is active, and the characteristic has a value, then the value is
    returned. In other words, this function takes precedence over the value that was given
    in the constructor or by $set-value/$write.
  */
  handle-read-request --timeout-ms/int=read-timeout-ms_ [block]:
    handle-request_ --for-read --timeout-ms=timeout-ms block

  /**
  Handles write requests.

  When new data is written to this characteristic, the given $block is called with the value.

  In many cases, the $read function is sufficient and easier to use. See below
    for reasons to use this function instead.

  This blocking function waits for write requests on this characteristic and calls the
    given $block for each request with the written value.

  If no request-handler is active, then the data is accumulated and can be
    read by calling $read. In other words, this function takes precedence over
    the $read function.

  If data was accumulated before the handler or `read` was called, then the $block is
    called with the accumulated data.

  While $read is easier to use, $handle-write-request may be necessary for characteristics
    that respond. The BLE stack will send a response only once the called $block has
    returned, thus ensuring that the data has been processed before the response is sent.
  */
  handle-write-request --timeout-ms/int=LocalService.DEFAULT-WRITE-TIMEOUT-MS [block]:
    handle-request_ --for-read=false --timeout-ms=timeout-ms block

  abstract handle-request_ --for-read/bool --timeout-ms/int [block]

  /**
  Adds a descriptor to this characteristic.

  $uuid is the uuid of the descriptor
  $properties is one of the CHARACTERISTIC-PROPERTY-* values (see
    $CHARACTERISTIC-PROPERTY-BROADCAST and similar).
  $permissions is one of the CHARACTERISTIC-PERMISSIONS-* values (see
    $CHARACTERISTIC-PERMISSION-READ and similar).
  if $value is specified, it is used as the initial value for the characteristic.

  The peripheral must not yet be deployed.

  Deprecated. Use $(add-descriptor uuid --properties --permissions --value) instead.
  */
  add-descriptor uuid/BleUuid properties/int permissions/int value/io.Data?=null -> LocalDescriptor:
    return add-descriptor uuid --properties=properties --permissions=permissions --value=value

  /**
  Adds a descriptor to this characteristic.

  $uuid is the uuid of the descriptor
  $properties is one of the CHARACTERISTIC-PROPERTY-* values (see
    $CHARACTERISTIC-PROPERTY-BROADCAST and similar).
  $permissions is one of the CHARACTERISTIC-PERMISSIONS-* values (see
    $CHARACTERISTIC-PERMISSION-READ and similar).
  If $value is specified, it is used as the initial value for the characteristic.

  The peripheral must not yet be deployed.
  */
  add-descriptor uuid/BleUuid --properties/int --permissions/int --value/io.Data?=null -> LocalDescriptor:
    if service.peripheral-manager.deployed: throw "Peripheral is already deployed"
    if (descriptors_.any: it.uuid == uuid): throw "Descriptor already exists"
    descriptor := create-descriptor_ uuid properties permissions value
    descriptors_.add descriptor
    return descriptor

  abstract create-descriptor_ uuid/BleUuid properties/int permissions/int value/io.Data? -> LocalDescriptor

  /**
  Adds a read-only descriptor to this characteristic with the given $uuid.

  If $secure is specified, the descriptor requires encryption.

  The peripheral must not yet be deployed.
  */
  add-descriptor uuid/BleUuid --value/io.Data --secure/bool=false -> LocalDescriptor:
    return add-descriptor uuid
        --properties=CHARACTERISTIC-PROPERTY-READ | CHARACTERISTIC-PROPERTY-WRITE
        --permissions=(secure ? CHARACTERISTIC-PERMISSION-READ-ENCRYPTED : CHARACTERISTIC-PERMISSION-READ)
        --value=value

  /**
  The handle of the characteristic.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  abstract handle -> int

abstract class LocalDescriptor extends LocalReadWriteElement_ implements Attribute:
  uuid/BleUuid
  characteristic/LocalCharacteristic
  permissions/int
  properties/int

  constructor.host_ .characteristic .uuid .properties .permissions:
    super.host_

  /**
  Closes this descriptor.
  */
  close_ -> none:
    characteristic.remove-descriptor_ this
    super

  /**
  Sets the value of the descriptor.

  This value is returned when a client reads the descriptor.

  In most cases $write is sufficient and easier to use. The main reason to use this function
    is to set a value without sending out any notification.
  */
  set-value value/io.Data:
    if (permissions & CHARACTERISTIC-PERMISSION-WRITE) == 0:
      throw "Invalid permission"
    set-value_ value

  abstract set-value_ value/io.Data

  /**
  Sets the value of this descriptor.

  Deprecated. Use $set-value instead.
  */
  write value/io.Data:
    set-value value

  /**
  Reads a value that is written to this descriptor.
  */
  read -> ByteArray:
    if (permissions & CHARACTERISTIC-PERMISSION-WRITE) == 0:
      throw "Invalid permission"
    return read_

  /**
  The handle of the descriptor.

  Typically, users do not need to access the handle directly. It may be useful
    for debugging purposes, but it is not required for normal operation.
  */
  abstract handle -> int

/** A local attribute a client can write to; the backend queues the written values. */
abstract class LocalReadWriteElement_ extends Resource_:
  constructor.host_:
    super.host_

  /** Waits for and returns the next value written by a client. */
  abstract read_ -> ByteArray
