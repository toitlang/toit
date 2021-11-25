// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import encoding.ubjson

RAT_LTE_M ::= 1
RAT_NB_IOT ::= 2
RAT_GSM ::= 3

interface Pin:
  on -> none
  off -> none

/**
Base for Cellular drivers for embedding in the kernel.
*/
interface Cellular:
  static DEFAULT_BAUD_RATE/int ::= 115200

  use_psm -> bool
  use_psm= value/bool -> none

  /**
  Returns the model of the Cellular module.
  */
  model -> string

  /**
  Returns the version of the Cellular module.
  */
  version -> string

  /**
  Returns the ICCID of the SIM card.
  */
  iccid -> string

  is_connected -> bool

  configure apn --bands/List?=null --rats/List?=null

  use_gsm rats/List? -> bool

  /**
  Connect to the service using the optional operator.
  */
  connect --operator/Operator?=null --use_gsm/bool -> bool

  /**
  Connect to the service after a PSM wakeup.
  */
  connect_psm

  /**
  Scan for operators.
  */
  scan_for_operators -> List

  get_connected_operator -> Operator?

  network_interface -> net.Interface

  detach -> none

  close -> none

  signal_strength -> float?

  wait_for_ready -> none

  enable_radio -> none

  disable_radio -> none

  power_on -> none

  /**
  Modem-specific implementation for recovering if the AT interface is unresponsive.
  */
  recover_modem -> none

  power_off -> none

  reset -> none

class Operator:
  op/string
  rat/int?

  constructor .op --.rat=null:

/**
GNSS location consisting of coordinates and accuracy measurements.
*/
class GnssLocation:
  latitude/float
  longitude/float
  /** The horizontal accuracy. */
  horizontal_accuracy ::= 0.0
  /** The vertical accuracy. */
  vertical_accuracy ::= 0.0
  /** The altitude relative to the median sea level. */
  altitude_msl ::= 0.0

  /**
  Constructs a GNSS location from the given $latitude, $longitude,
    $horizontal_accuracy, $vertical_accuracy, and $altitude_msl.
  */
  constructor .latitude .longitude .horizontal_accuracy .vertical_accuracy .altitude_msl:

  /**
  Constructs a GNSS location by deserializing the given bytes.

  The bytes must be constructed with $to_byte_array.
  */
  constructor.deserialize bytes/ByteArray?:
    values := ubjson.decode bytes
    return GnssLocation
      values[0]
      values[1]
      values[2]
      values[3]
      values[4]

  /**
  Serializes this GNSS location into a byte array.

  The bytes can be deserialized into a location with $GnssLocation.deserialize.
  */
  to_byte_array:
    return ubjson.encode [
      latitude,
      longitude,
      altitude_msl,
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

interface Gnss:
  gnss_start
  gnss_location -> GnssLocation?
  gnss_stop
