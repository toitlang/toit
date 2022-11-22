// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import device_impl_ as impl
import uuid
import encoding.tison

/**
Functionality available on devices (ESP32).
*/

interface Device_:
  name -> string?
  hardware_id -> uuid.Uuid
  estimate_time_accuracy -> int?


/** Name of this device. */
name -> string?:
  return impl.Device_.instance.name

/** Hardware ID of this device. */
hardware_id/uuid.Uuid ::= impl.Device_.instance.hardware_id

/**
Estimated time accuracy of this device.

On the device, the time drifts. The time is corrigated using the NTP when the
  devices goes online. The estimated time accuracy is the estimated time
  accuracy when the time was last set plus the an estimated time drift.
*/
estimate_time_accuracy -> int?:
  return impl.Device_.instance.estimate_time_accuracy

/** Simple key-value store. */
interface Store:
  get name/string
  delete name/string
  set name/string value/any

/**
Flash backed key-value store.

Key-value pairs are persisted in the flash, so they can be accessed across
  deep sleeps.
Make sure to remove obsolete key-value pairs using $delete.

The store is cleared on firmware updates.
*/
class FlashStore implements Store:
  /**
  Gets the value for the given $key.

  Returns null if no value is available.
  */
  get key/string -> any:
    return impl.FlashStore_.instance.get key

  /**
  Deletes the given $key from the store.

  The $key does not need to be present in the store.
  */
  delete key/string:
    impl.FlashStore_.instance.delete key

  /**
  Inserts the given $key-$value pair in the store.

  If the $key already exists in the store, then the value is overwritten.

  The $value is encoded as UBJSON. As such it supports:
  - literals: numbers, booleans, strings, null.
  - lists.
  - maps. The keys must be strings, and the values must be valid UBJSON objects.
  */
  set key/string value/any:
    impl.FlashStore_.instance.set key value

/**
Connection to the console.

Forces the kernel to attempt to connect to the console.
*/
class ConsoleConnection extends impl.ConsoleConnection_:
  /** Opens a connection to the console. */
  constructor.open:
    super.open

/**
Control of the GNSS module controlled by the kernel.
*/
class Gnss extends impl.Gnss_:
  /**
  Starts GNSS.

  The device must support GNSS.
  */
  constructor.start:
    super.start

  /**
  The location of this device.

  Returns null if there is no location fix.
  */
  location -> GnssLocation?:
    return super


/**
GNSS location consisting of coordinates and accuracy measurements.
*/
class GnssLocation:
  latitude/float
  longitude/float
  /** The altitude relative to the median sea level. */
  altitude_msl/float
  /** The time (UTC) when this location was recorded. */
  time/Time
  /** The horizontal accuracy. */
  horizontal_accuracy/float
  /** The vertical accuracy. */
  vertical_accuracy/float
  /**
  Constructs a GNSS location from the given $latitude, $longitude,
    $altitude_msl, $time, $horizontal_accuracy, and $vertical_accuracy.
  */
  constructor .latitude .longitude .altitude_msl .time .horizontal_accuracy .vertical_accuracy:

  /**
  Constructs a GNSS location by deserializing the given bytes.

  The bytes must be constructed with $to_byte_array.
  */
  constructor.deserialize bytes/ByteArray?:
    values := tison.decode bytes
    return GnssLocation
      values[0]
      values[1]
      values[2]
      Time.deserialize values[3]
      values[4]
      values[5]

  /**
  Serializes this GNSS location into a byte array.

  The bytes can be deserialized into a location with $GnssLocation.deserialize.
  */
  to_byte_array:
    return tison.encode [
      latitude,
      longitude,
      altitude_msl,
      time.to_byte_array,
      horizontal_accuracy,
      vertical_accuracy,
    ]

  /** See $super. */
  stringify:
    lat_printer := create_printer_ "S" "N"
    lat := lat_printer.call latitude

    long_printer := create_printer_ "W" "E"
    long := long_printer.call longitude

    return "$lat, $long"

  static create_printer_ negative_indicator_ positive_indicator_:
    return :: | value | "$(%3.5f value.abs)$(value < 0 ? negative_indicator_ : positive_indicator_)"
