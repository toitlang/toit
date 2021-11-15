// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .registers
/** Generic serial device. */

/**
A generic serial device that can be addressed for either
  direct I/O or through a register description.
*/
interface Device:
  /**
  Register description of this device.
  */
  registers -> Registers

  /**
  Reads the $amount of bytes from the device.

  If the device can't provide $amount bytes, the behavior of this operation
    is undefined and depending on the actual device implementation.
  */
  read amount/int -> ByteArray

  /**
  Writes the $bytes to the device.

  If the device can't accept the $bytes, the behavior of this operation
    is undefined and depending on the actual device implementation.
  */
  write bytes/ByteArray -> none
