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
  the "base UUID".
Similarly, a 32-bit UUID of the form "XXXXXXXX" is a short-hand for
  "XXXXXXXX-0000-1000-8000-00805F9B34FB".

See https://www.bluetooth.com/specifications/assigned-numbers/ for a list of
  assigned UUIDs.
*/
class BleUuid:
  data_/io.Data  // Either a ByteArray or a string.

  /**
  Constructs a new UUID from a byte array or a string.

  Does not check if a UUID can be shrunk by using the base UUID.
  */
  constructor data/io.Data:
    if data is not ByteArray and data is not string:
      data = ByteArray.from data
    data_ = data
    if data_ is ByteArray:
      bytes := data_ as ByteArray
      if bytes.size != 2 and bytes.size != 4 and bytes.size != 16: throw "INVALID UUID"
    else if data_ is string:
      str := data_ as string
      if str.size != 4 and str.size != 8 and str.size != 36: throw "INVALID UUID"
      if str.size == 36:
        uuid.Uuid.parse str // This throws an exception if the format is incorrect.
      else:
        if (catch: hex.decode str):
          throw "INVALID UUID $str"
      str = str.to-ascii-lower

  /**
  Constructs a new UUID from a 16-bit UUID where the $bytes are reversed.
  */
  constructor.from-reversed bytes/ByteArray:
    return BleUuid bytes.reverse

  /**
  Returns the UUID as a string of the form "XXXX" (16-bit UUID), "XXXXXXXX"
    (32-bit UUID), or "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" (other UUIDs).
  */
  to-string -> string:
    if data_ is ByteArray:
      bytes := data_ as ByteArray
      if bytes.size <= 8:
        return hex.encode bytes
      else:
        return (uuid.Uuid bytes).stringify
    else:
      return data_ as string

  /**
  Returns a string representation of this UUID.

  If a deterministic UUID string representation is needed, prefer using $to-string.
  */
  stringify -> string:
    return to-string

  /**
  Returns the UUID as a byte array.

  The result is 2 bytes long for 16-bit UUIDs, 4 bytes long for 32-bit UUIDs,
    and 16 bytes long for 128-bit UUIDs.
  */
  to-byte-array --reversed/bool=false -> ByteArray:
    result/ByteArray := ?
    if data_ is string:
      str := data_ as string
      if str.size <= 8:
        result = hex.decode str
      else:
        result = (uuid.Uuid.parse str).to-byte-array
    else:
      result = data_ as ByteArray
      if reversed: result = result.copy
    if reversed: result.reverse --in-place
    return result

  encode-for-platform_:
    if ble-platform-requires-uuid-as-byte-array_:
      return to-byte-array
    else:
      return to-string

  hash-code -> int:
    return to-byte-array.hash-code

  operator== other/BleUuid:
    return to-byte-array == other.to-byte-array

  /** The size, in bytes, of the UUID. */
  byte-size -> int:
    if data_ is ByteArray: return (data_ as ByteArray).size
    return to-byte-array.size

  /** The size, in bits, of the UUID. */
  bit-size -> int:
    return byte-size * 8

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

/**
A device that is discoverable for a limited period of time.

See the core specification Section 9.2.3.
https://www.bluetooth.com/specifications/specs/core-specification-6-0/
*/
BLE-ADVERTISE-FLAGS-LIMITED-DISCOVERY  ::= 0x01

/**
A device that is discoverable for an indefinite period of time.

See the core specification Section 9.2.4.
https://www.bluetooth.com/specifications/specs/core-specification-6-0/
*/
BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY  ::= 0x02

/**
A device that doesn't support the Bluetooth Classic radio.

Since Toit only supports BLE, this flag should always be set.
*/
BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED  ::= 0x04

BLE-DEFAULT-PREFERRED-MTU_             ::= 23

/**
A Bluetooth data block.

Data blocks are used in advertising data (AD) and scan response data (SRD) to
  provide information about the device. They are also used in an extended
  inquiry response (EIR), additional controller advertising data (ACAD), and
  OOB data blocks.

The possible types are listed in section 2.3 of the Bluetooth
  "Assigned Numbers" document:
  https://www.bluetooth.com/specifications/assigned-numbers/

The core specification supplement discusses the encoding of the data:
  https://www.bluetooth.com/specifications/specs/core-specification-supplement/
*/
// I found the following link helpful:
//   https://jimmywongiot.com/2019/08/13/advertising-payload-format-on-ble/
class DataBlock:
  static TYPE-FLAGS ::= 0x01
  static TYPE-SERVICE-UUIDS-16-INCOMPLETE ::= 0x02
  static TYPE-SERVICE-UUIDS-16-COMPLETE ::= 0x03
  static TYPE-SERVICE-UUIDS-32-INCOMPLETE ::= 0x04
  static TYPE-SERVICE-UUIDS-32-COMPLETE ::= 0x05
  static TYPE-SERVICE-UUIDS-128-INCOMPLETE ::= 0x06
  static TYPE-SERVICE-UUIDS-128-COMPLETE ::= 0x07
  static TYPE-NAME-SHORTENED ::= 0x08
  static TYPE-NAME-COMPLETE ::= 0x09
  static TYPE-TX-POWER-LEVEL ::= 0x0A
  static TYPE-SERVICE-DATA-16 ::= 0x16
  static TYPE-SERVICE-DATA-32 ::= 0x20
  static TYPE-SERVICE-DATA-128 ::= 0x21
  static TYPE-MANUFACTURER-SPECIFIC ::= 0xFF

  /**
  The type of the data block.

  The types are defined in the Bluetooth "Assigned Numbers" document:
    https://www.bluetooth.com/specifications/assigned-numbers/, section 2.3.

  Some types have constants defined in this class: $TYPE-FLAGS, ...
  */
  type/int

  /**
  The data of the data block.
  */
  data/ByteArray

  static encode-uuids_ uuids/List --uuid-byte-size/int -> ByteArray:
    result := ByteArray uuids.size * uuid-byte-size
    pos := 0
    uuids.do: | uuid/BleUuid |
      bytes := uuid.to-byte-array --reversed
      if bytes.size != uuid-byte-size: throw "INVALID_UUID_SIZE"
      result.replace pos bytes
      pos += uuid-byte-size
    return result

  static decode-uuids_ bytes/ByteArray --uuid-byte-size/int -> List:
    if bytes.size % uuid-byte-size != 0: throw "INVALID_UUID_SIZE"
    result := []
    (bytes.size / uuid-byte-size).repeat: | i/int |
      uuid-bytes := bytes[i * uuid-byte-size .. (i + 1) * uuid-byte-size]
      result.add (BleUuid.from-reversed uuid-bytes)
    return result

  static encode-service-data_ uuid/BleUuid service-data/io.Data [block] -> none:
    uuid-bytes := uuid.to-byte-array --reversed
    data := ByteArray uuid-bytes.size + service-data.byte-size
    data.replace 0 uuid-bytes
    service-data.write-to-byte-array data --at=uuid-bytes.size 0 service-data.byte-size
    block.call uuid-bytes.size data

  static decode-service-data_ bytes/ByteArray --uuid-byte-size/int [block] -> any:
    if bytes.size < uuid-byte-size: throw "INVALID_DATA"
    uuid := BleUuid.from-reversed bytes[0 .. uuid-byte-size]
    service-data := bytes[uuid-byte-size ..]
    return block.call uuid service-data

  /**
  Decodes a raw advertisement data packet into a list of data blocks.
  */
  static decode raw/ByteArray -> List:
    result := []
    pos := 0
    while pos < raw.size:
      if pos + 1 >= raw.size: throw "INVALID_DATA"
      size := raw[pos]
      if size == 0: throw "INVALID_DATA"
      if pos + size >= raw.size: throw "INVALID_DATA"
      type := raw[pos + 1]
      data := raw[pos + 2 .. pos + size + 1].copy
      result.add (DataBlock type data)
      pos += 1 + size
    return result

  /**
  Constructs a new advertisement data field.

  No check is made to ensure that the data is valid for the given type.
  */
  constructor .type .data:

  /**
  Constructs a field of flags for discovery.

  Each bit of the $flags value encodes a boolean.

  Bit 0: LE Limited Discoverable Mode, $BLE-ADVERTISE-FLAGS-LIMITED-DISCOVERY.
  Bit 1: LE General Discoverable Mode, $BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY.
  Bit 2: BR/EDR Not Supported (i.e., bit 37 of LMP Feature Mask Page 0). "BR/EDR" is
    the Bluetooth Classic radio, and not supported by Toit. $BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED.
  Bit 3: Simultaneous LE and BR/EDR to Same Device Capable (controller).
  Bit 4: Previously Used.

  The flags field may be 0 or multiple octets long. Currently, only the first octet
    is used.

  The flags field must not be present in the scan response data; only in
    the advertising data.
  The flags field is optional and may only be present once.
  */
  constructor.flags flags/int:
    if not 0 <= flags < 256: throw "INVALID_FLAGS"
    type = TYPE-FLAGS
    if flags == 0:
      data = #[]
    else:
      data = #[flags]

  /**
  Variant of $DataBlock.flags.

  Allows to specify some flags using named arguments.
  */
  constructor.flags
      --limited-discovery/True
      --bredr-supported/bool=false:
    flags := BLE-ADVERTISE-FLAGS-LIMITED-DISCOVERY
    if not bredr-supported: flags |= BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED
    return DataBlock.flags flags

  /**
  Variant of $DataBlock.flags.

  Allows to specify some flags using named arguments.
  */
  constructor.flags
      --general-discovery/True
      --bredr-supported/bool=false:
    flags := BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY
    if not bredr-supported: flags |= BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED
    return DataBlock.flags flags

  /**
  Constructs a field with a list of 16-bit service UUIDs.

  If $incomplete is true, then the list is incomplete.

  Omitting the service UUIDs is equivalent to providing an empty
    *incomplete* list. Provide an empty list to indicate that no service UUIDs
    are present.

  UUID service fields are optional. Only one field per size (16, 32, 128 bits)
    may be present.
  The specification is not clear on whether the advertising data may contain
    an incomplete list of service UUIDs and the scan response contain the
    complete list.
  */
  constructor.services-16 uuids/List --incomplete/bool=false:
    if incomplete:
      type = TYPE-SERVICE-UUIDS-16-INCOMPLETE
    else:
      type = TYPE-SERVICE-UUIDS-16-COMPLETE
    data = encode-uuids_ uuids --uuid-byte-size=2

  /**
  Constructs a field with a list of 32-bit service UUIDs.

  See $DataBlock.services-16 for more information.
  */
  constructor.services-32 uuids/List --incomplete/bool=false:
    if incomplete:
      type = TYPE-SERVICE-UUIDS-32-INCOMPLETE
    else:
      type = TYPE-SERVICE-UUIDS-32-COMPLETE
    data = encode-uuids_ uuids --uuid-byte-size=4

  /**
  Constructs a field with a list of 128-bit service UUIDs.

  See $DataBlock.services-16 for more information.
  */
  constructor.services-128 uuids/List --incomplete/bool=false:
    if incomplete:
      type = TYPE-SERVICE-UUIDS-128-INCOMPLETE
    else:
      type = TYPE-SERVICE-UUIDS-128-COMPLETE
    data = encode-uuids_ uuids --uuid-byte-size=16

  /**
  Constructs a field with the name of the device.

  If $shortened is true, then the name is not complete. The complete name may
    be retrieved by reading the device name characteristic after the connection
    has been established using GATT.
  It might also be allowed to have an incomplete name in the advertising data, and
    the complete name in the scan response. The specification isn't clear on this.

  If an incomplete name is provided, it must be a prefix of the complete name.
  The name field is optional and may only be present once.
  */
  constructor.name name/string --shortened/bool=false:
    if name.size > 31: throw "NAME_TOO_LONG"
    if shortened:
      type = TYPE-NAME-SHORTENED
    else:
      type = TYPE-NAME-COMPLETE
    data = name.to-byte-array

  /**
  Constructs a field with the transmit power level.

  The transmit power level is the power level at which the packet was transmitted.

  The power level may be used to calculate path loss on a received packet using
    the following equation: path-loss = tx-power - rssi (where 'rssi' is the
    received signal strength indicator).

  For example, if the TX power level is +4 (dBm) and the RSSI on the received
    packet is -60 (dBm) the the total path loss is +4 - (-60) = +64 dB.

  The TX power level field is optional.
  */
  constructor.tx-power-level tx-power-level/int:
    if not -127 <= tx-power-level <= 127: throw "INVALID_TX_POWER_LEVEL"
    type = TYPE-TX-POWER-LEVEL
    data = #[tx-power-level]

  /**
  Constructs a field with data for a service UUID.

  This field consists of a service UUID with the data associated with that service.

  This field is optional and may appear multiple times.
  */
  constructor.service-data uuid/BleUuid service-data/io.Data:
    data = #[]  // Needed to make the compiler happy.
    type = 0  // Needed to make the compiler happy.
    encode-service-data_ uuid service-data: | uuid-byte-size encoded-data |
      this.data = encoded-data
      if uuid-byte-size == 2:
        type = TYPE-SERVICE-DATA-16
      else if uuid-byte-size == 4:
        type = TYPE-SERVICE-DATA-32
      else if uuid-byte-size == 16:
        type = TYPE-SERVICE-DATA-128
      else:
        throw "INVALID_UUID_SIZE"

  /**
  Constructs a field with manufacturer specific data.

  This field is optional and may appear multiple times.

  The $company-id is a 16-bit value that is assigned by the Bluetooth SIG. The
    value 0xFFFF is reserved for internal use.
  */
  constructor.manufacturer-specific manufacturer-data/io.Data --company-id/ByteArray=#[0xFF, 0xFF]:
    if company-id.size != 2: throw "INVALID_COMPANY_ID"
    type = TYPE-MANUFACTURER-SPECIFIC
    bytes := ByteArray 2 + manufacturer-data.byte-size
    bytes.replace 0 company-id
    manufacturer-data.write-to-byte-array bytes --at=2 0 manufacturer-data.byte-size
    data = bytes

  /** Whether this data block encodes the flags field ($TYPE-FLAGS). */
  is-flags -> bool:
    return type == TYPE-FLAGS

  /**
  Returns the value of the flags field.

  See $DataBlock.flags for more information on the bits.
  */
  flags -> int:
    if not is-flags: throw "INVALID_TYPE"
    if data.is-empty: return 0
    return data[0]

  /**
  Whether this data block encodes a name ($TYPE-NAME-SHORTENED or $TYPE-NAME-COMPLETE).

  Check the $type against $TYPE-NAME-COMPLETE to know whether the name is complete.
  */
  is-name -> bool:
    return type == TYPE-NAME-SHORTENED or type == TYPE-NAME-COMPLETE

  /**
  Returns the (possibly shortened) name of the device.

  If the name is incomplete, it is a prefix of the complete name.

  Check the $type against $TYPE-NAME-COMPLETE to know whether the name is complete.
  */
  name -> string:
    if not is-name: throw "INVALID_TYPE"
    return data.to-string

  /**
  Whether this data block encodes service UUIDs.

  Check the $type against $TYPE-SERVICE-UUIDS-16-COMPLETE to know whether
    the list is complete.
  */
  is-services-16 -> bool:
    return type == TYPE-SERVICE-UUIDS-16-INCOMPLETE or type == TYPE-SERVICE-UUIDS-16-COMPLETE

  /**
  Returns a (potentially incomplete) list of 16-bit service UUIDs.

  Check the $type against $TYPE-SERVICE-UUIDS-16-COMPLETE to know whether
    the list is complete.

  See $DataBlock.services-16 for more information.
  */
  services-16 -> List:
    if not is-services-16: throw "INVALID_TYPE"
    return decode-uuids_ data --uuid-byte-size=2

  /**
  Whether this data block encodes 32-bit service UUIDs.

  See $is-services-16.
  */
  is-services-32 -> bool:
    return type == TYPE-SERVICE-UUIDS-32-INCOMPLETE or type == TYPE-SERVICE-UUIDS-32-COMPLETE

  /**
  Returns a (potentially incomplete) list of 32-bit service UUIDs.

  See $services-16.
  */
  services-32 -> List:
    if not is-services-32: throw "INVALID_TYPE"
    return decode-uuids_ data --uuid-byte-size=4

  /**
  Whether this data block encodes 128-bit service UUIDs.

  See $is-services-16.
  */
  is-services-128 -> bool:
    return type == TYPE-SERVICE-UUIDS-128-INCOMPLETE or type == TYPE-SERVICE-UUIDS-128-COMPLETE

  /**
  Returns a (potentially incomplete) list of 128-bit service UUIDs.

  See $services-16.
  */
  services-128 -> List:
    if not is-services-128: throw "INVALID_TYPE"
    return decode-uuids_ data --uuid-byte-size=16

  /**
  Whether this data block encodes service uuids.

  This is a convenience function that checks all three types of service UUIDs.
  See $is-services-16, $is-services-32, and $is-services-128.
  */
  is-services -> bool:
    return is-services-16 or is-services-32 or is-services-128

  /**
  Returns a list of service UUIDs.

  This is a convenience function that checks all three types of service UUIDs.
  See $services-16, $services-32, and $services-128.
  */
  services -> List:
    if is-services-16: return services-16
    if is-services-32: return services-32
    if is-services-128: return services-128
    throw "INVALID_TYPE"

  /**
  Returns whether this data block contains the given service UUID.
  */
  contains-service uuid/BleUuid -> bool:
    byte-size := uuid.byte-size
    if byte-size == 2 and is-services-16 or
        byte-size == 4 and is-services-32 or
        byte-size == 16 and is-services-128:
      bytes := uuid.to-byte-array --reversed
      for i := 0; i < data.size; i += byte-size:
        j := 0
        while j < byte-size:
          if data[i + j] != bytes[j]: break
          j++
        if j == byte-size: return true
    return false

  /**
  Whether this data block encodes the transmit power level ($TYPE-TX-POWER-LEVEL).
  */
  is-tx-power-level -> bool:
    return type == TYPE-TX-POWER-LEVEL

  /**
  Returns the transmit power level.

  See $DataBlock.tx-power-level for more information.
  */
  tx-power-level -> int:
    if not is-tx-power-level: throw "INVALID_TYPE"
    value := data[0]
    if value >= 128: return value - 256
    return value

  /** Whether this data block encodes data for a service UUID. */
  is-service-data -> bool:
    return type == TYPE-SERVICE-DATA-16 or
        type == TYPE-SERVICE-DATA-32 or
        type == TYPE-SERVICE-DATA-128

  /** Whether this data block encodes data for the given uuid. */
  is-service-data-for uuid/BleUuid -> bool:
    uuid-bytes := uuid.to-byte-array --reversed
    if uuid-bytes.size == 2:
      return type == TYPE-SERVICE-DATA-16 and data[0 .. 1] == uuid-bytes
    else if uuid-bytes.size == 4:
      return type == TYPE-SERVICE-DATA-32 and data[0 .. 3] == uuid-bytes
    else if uuid-bytes.size == 16:
      return type == TYPE-SERVICE-DATA-128 and data[0 .. 15] == uuid-bytes
    return false

  /**
  Calls the given block with the UUID and data of the service data block.

  Returns the result of calling the block.

  See $DataBlock.service-data for more information.
  */
  service-data [block] -> any:
    if not is-service-data: throw "INVALID_TYPE"
    byte-size/int := ?
    if type == TYPE-SERVICE-DATA-16: byte-size = 2
    else if type == TYPE-SERVICE-DATA-32: byte-size = 4
    else if type == TYPE-SERVICE-DATA-128: byte-size = 16
    else: unreachable
    return decode-service-data_ data --uuid-byte-size=byte-size block

  /** Whether this data block encodes manufacturer specific data. */
  is-manufacturer-specific -> bool:
    return type == TYPE-MANUFACTURER-SPECIFIC

  /**
  Calls the given $block with the company ID and manufacturer specific data.

  Returns the result of calling the block.

  See $DataBlock.manufacturer-specific for more information.
  */
  manufacturer-specific [block] -> any:
    if not is-manufacturer-specific: throw "INVALID_TYPE"
    return block.call data[0 .. 2] data[2 ..]

  /**
  Writes this field into the given $bytes at the given position $at.
  */
  write bytes/ByteArray --at/int [--on-error] -> int:
    if bytes.size < at + 2:
      return on-error.call "BUFFER_TOO_SMALL"
    bytes[at] = data.size + 1
    bytes[at + 1] = type
    bytes.replace (at + 2) data
    return at + data.size + 2

  /**
  Converts this data block to a raw byte array.
  */
  to-raw -> ByteArray:
    result := ByteArray data.size + 2
    result[0] = data.size + 1
    result[1] = type
    result.replace 2 data
    return result

/**
Deprecated. Use $Advertisement instead.
*/
class AdvertisementData extends Advertisement:
  /**
  Deprecated. Use the $Advertisement.constructor instead. The argument $manufacturer-data has
    been renamed to 'manufacturer-specific', and $service-classes has been renamed to 'services'.
  */
  constructor
      --name/string?=null
      --service-classes/List=[]
      --manufacturer-data/io.Data=#[]
      --.connectable=false
      --flags/int=0
      --check-size/bool=true:
    super
        --name=name
        --services=service-classes
        --manufacturer-specific=manufacturer-data.byte-size > 0 ? manufacturer-data : null
        --flags=flags
        --check-size=check-size

  constructor.raw_ bytes/ByteArray? --.connectable:
    super.raw bytes

  /**
  Whether connections are allowed.

  Deprecated: Use $RemoteScannedDevice.is-connectable instead.
  */
  connectable/bool

  /**
  Advertised service classes as a list of $BleUuid.

  Deprecated. Use $Advertisement.services instead.
  */
  service-classes -> List: return services

  /**
  Manufacturer data as a byte array.

  For backwards compatibility, returns an empty byte array if no manufacturer data is present.

  Returns the concatenation of the manufacturer-id and the manufacturer-specific data.

  Deprecated. Use $Advertisement.manufacturer-specific instead.
  */
  manufacturer-data -> ByteArray:
    data-blocks.do: | block/DataBlock |
      if block.is-manufacturer-specific: return block.data.copy
    return ByteArray 0

/**
Advertisement data as either sent by advertising or received through scanning.

The size of an advertisement packet is limited to 31 bytes. This includes the name
  and bytes that are required to structure the packet.
*/
class Advertisement:
  /** The $DataBlock fields of this instance. */
  data-blocks/List  // Of DataBlock.

  /**
  Constructs an advertisement data packet with the given data blocks.

  Advertisement packets are limited to 31 data bytes. If $check-size is true, then
    the size of the data blocks is checked to ensure that the packet size does not
    exceed 31 bytes.
  */
  constructor .data-blocks --check-size/bool=true:
    if check-size and size > 31: throw "PACKET_SIZE_EXCEEDED"

  /**
  Constructs an advertisement data packet from the $raw data.

  Advertisement packets are limited to 31 data bytes.
  */
  constructor.raw raw/ByteArray?:
    data-blocks = raw ? DataBlock.decode raw : []

  /**
  Constructs an advertisement packet.

  If the $services parameter is not empty, then the list is split into 16-bit, 32-bit,
    and 128-bit UUIDs. Each of the lists that isn't empty is then encoded into the
    advertisement data.
  */
  constructor
      --name/string?=null
      --services/List=[]
      --manufacturer-specific/io.Data?=null
      --flags/int?=null
      --check-size/bool=true:
    blocks := []
    if name: blocks.add (DataBlock.name name)
    if not services.is-empty:
      uuids-16 := []
      uuids-32 := []
      uuids-128 := []
      services.do: | uuid/BleUuid |
        if uuid.to-byte-array.size == 2: uuids-16.add uuid
        else if uuid.to-byte-array.size == 4: uuids-32.add uuid
        else: uuids-128.add uuid
      if not uuids-16.is-empty: blocks.add (DataBlock.services-16 uuids-16)
      if not uuids-32.is-empty: blocks.add (DataBlock.services-32 uuids-32)
      if not uuids-128.is-empty: blocks.add (DataBlock.services-128 uuids-128)
    if manufacturer-specific: blocks.add (DataBlock.manufacturer-specific manufacturer-specific)
    if flags: blocks.add (DataBlock.flags flags)
    data-blocks = blocks

    if check-size:
      size := 0
      data-blocks.do: | block/DataBlock |
        size += 2 + block.data.size
      if size > 31: throw "PACKET_SIZE_EXCEEDED"

  /**
  The advertised name of the device.
  */
  name -> string?:
    data-blocks.do: | block/DataBlock |
      if block.is-name: return block.name
    return null

  /**
  Advertised services as a list of $BleUuid.

  Returns the empty list if no services are present.
  */
  services -> List?:
    result := []
    data-blocks.do: | block/DataBlock |
      if block.is-services:
        result.add-all block.services
    return result

  /**
  Whether this advertisement contains the given service UUID.
  */
  contains-service uuid/BleUuid -> bool:
    data-blocks.do: | block/DataBlock |
      if block.is-services and block.contains-service uuid: return true
    return false

  /**
  Advertise flags. This must be a bitwise 'or' of the BLE-ADVERTISE-FLAG_* constants
    (see $BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY and similar).

  For backwards compatibility, returns 0 if no flags are present.
  */
  flags -> int:
    data-blocks.do: | block/DataBlock |
      if block.is-flags: return block.flags
    return 0

  /**
  The transmit power level.
  */
  tx-power-level -> int?:
    data-blocks.do: | block/DataBlock |
      if block.is-tx-power-level: return block.tx-power-level
    return null

  /**
  Calls the given $block with the first field of manufacturer specific data.

  Calls the block with the company ID and manufacturer specific data.
  If no manufacturer specific data is present, the block is not called.

  Returns the result of calling the block, or null if no manufacturer specific data is present.
  */
  manufacturer-specific [block] -> any:
    data-blocks.do: | data-block/DataBlock |
      if data-block.is-manufacturer-specific:
        return data-block.manufacturer-specific block
    return null

  /**
  The size of the advertisement data packet.

  Returns the size of all the data blocks.
  */
  size -> int:
    size := 0
    data-blocks.do: | block/DataBlock |
      size += 2 + block.data.size
    return size

  /**
  Encodes the advertisement data into a byte array.

  Does not check if the size of the advertisement data exceeds 31 bytes.
  */
  to-raw -> ByteArray:
    result := ByteArray size
    pos := 0
    data-blocks.do: | block/DataBlock |
      pos = block.write result --at=pos --on-error=: throw it
    return result

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

  If $name is provided, it is used for the GAP name. The GAP name can be different from the
    advertised name in the advertisement data. On some platforms, the GAP name is stored
    and will be used in future calls to this method (if the name is not provided).
  */
  peripheral --bonding/bool=false --secure-connections/bool=false --name/string?=null -> Peripheral:
    if not adapter-metadata.supports-peripheral-role: throw "NOT_SUPPORTED"
    if name: ble-set-gap-device-name_ resource_ name
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

ble-scan-start_ central-manager passive/bool duration-us/int interval/int window/int limited/bool:
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

ble-advertise-start_ peripheral-manager name services interval_us connection-mode flags:
  #primitive.ble.advertise-start

ble-advertise-start-raw_ peripheral-manager advertising-packet/ByteArray scan-response/ByteArray? interval_us/int connection-mode/int:
  #primitive.ble.advertise-start-raw

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

ble-set-gap-device-name_ resource name:
  #primitive.ble.set-gap-device-name
