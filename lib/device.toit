// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import drivers.cellular
import device_impl as impl
import uuid


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
    impl.FlashStore_.instance.get key

  /**
  Inserts the given $key-$value pair in the store.

  If the $key already exists in the store, then the value is overwritten.
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
  location -> cellular.GnssLocation?:
    return super
