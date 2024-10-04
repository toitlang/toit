// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor
import uuid
import monitor show ResourceState_
import system
import encoding.hex

import .local
import .remote

export *

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
        uuid.Uuid.parse data_ // This throws an exception if the format is incorrect.
      else:
        if (catch: hex.decode data_):
          throw "INVALID UUID $data_"
      data_ = data_.to-ascii-lower
    else:
      throw "TYPE ERROR: data is not a string or byte array"

  /**
  Returns the UUID as a string of the form "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX".
  */
  to-string -> string:
    if data_ is ByteArray:
      if data_.size <= 4:
        return hex.encode data_
      else:
        return (uuid.Uuid data_).stringify
    else:
      return data_

  /**
  Returns a string representation of this UUID.

  If a deterministic UUID string representation is needed, prefer using $to-string.
  */
  stringify -> string:
    return to-string

  to-byte-array:
    if data_ is string:
      if data_.size <= 4: return hex.decode data_
      return (uuid.Uuid.parse data_).to-byte-array
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
  manufacturer-data_/io.Data

  /**
  Whether connections are allowed.
  */
  connectable/bool

  /**
  Advertise flags. This must be a bitwise 'or' of the BLE-ADVERTISE-FLAG_* constants
    (see $BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY and similar).
  */
  flags/int

  constructor --.name=null --.service-classes=[] --manufacturer-data/io.Data=#[]
              --.connectable=false --.flags=0 --check-size=true:
    manufacturer-data_ = manufacturer-data
    size := 0
    if name: size += 2 + name.size
    service-classes.do: | uuid/BleUuid |
      size += 2 + uuid.to-byte-array.size
    if manufacturer-data.byte-size > 0: size += 2 + manufacturer-data.byte-size
    if size > 31 and check-size: throw "PACKET_SIZE_EXCEEDED"

  manufacturer-data -> ByteArray:
    if manufacturer-data_ is ByteArray:
      return manufacturer-data_ as ByteArray
    return ByteArray.from manufacturer-data_


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

  If $secure-connections is true then the peripheral is enabling secure connections.
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
DATA-WRITE-REQUEST-EVENT_             ::= 1 << 24


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

ble-write-value_ characteristic value with-response:
  return ble-run-with-quota-backoff_: | last-attempt/bool |
    ble-write-value__ characteristic value with-response (not last-attempt)

ble-write-value__ characteristic value/io.Data with-response allow-retry:
  #primitive.ble.write-value:
    return io.primitive-redo-io-data_ it value: | bytes |
      ble-write-value__ characteristic bytes with-response allow-retry

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
    if value == null: throw it
    return io.primitive-redo-io-data_ it value: | bytes |
      ble-add-characteristic__ service uuid properties permission bytes

ble-add-descriptor_ characteristic uuid properties permission value:
  return ble-run-with-quota-backoff_:
    ble-add-descriptor__ characteristic uuid properties permission value

ble-add-descriptor__ characteristic uuid properties permission value:
  #primitive.ble.add-descriptor:
    if value == null: throw it
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
    if new-value == null: throw it
    return io.primitive-redo-io-data_ it new-value: | bytes |
      ble-set-value__ characteristic bytes

ble-get-subscribed-clients characteristic:
  #primitive.ble.get-subscribed-clients

ble-notify-characteristics-value_ characteristic client new-value:
  return ble-run-with-quota-backoff_:
    ble-notify-characteristics-value__ characteristic client new-value

ble-notify-characteristics-value__ characteristic client new-value:
  #primitive.ble.notify-characteristics-value:
    if new-value == null: throw it
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
  return system.platform == system.PLATFORM-FREERTOS

ble-callback-init_ resource timeout-ms for-read:
  #primitive.ble.toit-callback-init

ble-callback-deinit_ resource for-read:
  #primitive.ble.toit-callback-deinit

ble-callback-reply_ resource value for-read:
  ble-run-with-quota-backoff_ :
    ble-callback-reply__ resource value for-read

ble-callback-reply__ resource value for-read:
  #primitive.ble.toit-callback-reply:
    if value == null: throw it
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
