// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .advertisement
import .host
import .local
import .remote
import .uuid

/**
The adapter of the `ble` package and the constants and interfaces its
  classes share; `ble` re-exports it.
*/

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

/**
This device should not be connected to.

See the core specification Section 9.3.2.
https://www.bluetooth.com/specifications/specs/core-specification-6-0/
*/
BLE-CONNECT-MODE-NONE ::= 0

/**
This device accepts a connection from a known peer device.

See the core specification Section 9.3.3.
https://www.bluetooth.com/specifications/specs/core-specification-6-0/
*/
BLE-CONNECT-MODE-DIRECTIONAL ::= 1

/**
This device accepts connections from any device.

See the core specification Section 9.3.4.
https://www.bluetooth.com/specifications/specs/core-specification-6-0/
*/
BLE-CONNECT-MODE-UNDIRECTIONAL         ::= 2


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


/**
Describes an adapter: its $identifier, its $address and the roles it
  supports.

The Toit host backend fills it in from the capabilities of its BLE
  service provider.
*/
class AdapterMetadata:
  identifier/string
  address/ByteArray
  supports-central-role/bool
  supports-peripheral-role/bool
  handle_/any

  constructor.private_ .identifier .address .supports-central-role .supports-peripheral-role .handle_:

/**
An adapter represents the chip or peripheral that is used to communicate over BLE.

The adapter is the Toit host's: it reaches the radio through the BLE
  service provider, which is built into the ESP32 firmware and runs
  in-process on Linux. Its $central and $peripheral managers take the
  two roles.
*/
abstract class Adapter extends Resource_:
  adapter-metadata/AdapterMetadata?
  central_/Central? := null
  peripheral_/Peripheral? := null

  /**
  Opens the default adapter.

  The adapter is the Toit host's, reached through its BLE service
    provider. Throws "Unsupported platform" when no provider is
    available.
  */
  constructor:
    return host-adapter_

  constructor.host_ .adapter-metadata:
    super.host_

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
    if not central_: central_ = create-central_
    return central_

  abstract create-central_ -> Central

  remove-central_ central/Central -> none:
    assert: central == central_
    central_ = null

  /**
  The peripheral manager is used to advertise and publish local services.

  If $bonding is true then the peripheral is allowing remote centrals to bond. In that
    case the information of the pairing process may be stored on the device to make
    reconnects more efficient.

  If $secure-connections is true then the peripheral is enabling secure connections.

  If $name is provided, it is used for the GAP name. The GAP name can be different from the
    advertised name in the advertisement data. On some platforms, the GAP name is stored
    and will be used in future calls to this method (if the name is not provided).
  */
  peripheral --bonding/bool=false --secure-connections/bool=false --name/string?=null -> Peripheral:
    if not adapter-metadata.supports-peripheral-role: throw "NOT_SUPPORTED"
    if not peripheral_: peripheral_ = create-peripheral_ bonding secure-connections name
    return peripheral_

  abstract create-peripheral_ bonding/bool secure-connections/bool name/string? -> Peripheral

  remove-peripheral_ peripheral/Peripheral -> none:
    assert: peripheral == peripheral_
    peripheral_ = null

  abstract set-preferred-mtu mtu/int

/**
The common base of the adapter, its managers and their attributes.

Each subclass tracks its own lifetime and reports it through $is-closed.
  The closing hooks of the subclasses chain to $close_, which holds
  nothing itself.
*/
abstract class Resource_:
  constructor.host_:

  /** Whether this resource has been closed. */
  abstract is-closed -> bool

  /** Releases what this resource holds; overrides call `super`. */
  close_ -> none:
