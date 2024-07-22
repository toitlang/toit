// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import spi
import gpio

FREQUENCY-5MHZ  ::= 0
FREQUENCY-10MHZ ::= 1
FREQUENCY-20MHZ ::= 2
FREQUENCY-26MHZ ::= 3
FREQUENCY-40MHZ ::= 4
FREQUENCY-80MHZ ::= 5

class Mount:
  flash_ := null
  mount-point/string

  /**
  Mounts an SD-card as a FAT file system under $mount-point on the $spi-bus without formatting the flash.

  The $cs is the chip select pin for the SD-card holder.
  */
  constructor.sdcard-unformatted
      --.mount-point/string
      --spi-bus/spi.Bus
      --cs/gpio.Pin:
    if not mount-point.starts-with "/": throw "INVALID_ARGUMENT"
    flash_ = init-sdcard_ mount-point spi-bus.spi_ cs.num 0 0 0

  /**
  Mounts an SD-card as a FAT file system under $mount-point on the $spi-bus and formats the SD-card
    with $max-files and $allocation-unit-size if it is not already formatted.

  The $cs is the chip select pin for the SD-card holder.
  */
  constructor.sdcard
      --.mount-point/string
      --spi-bus/spi.Bus
      --cs/gpio.Pin
      --max-files/int=5
      --allocation-unit-size/int=16384:
    if not mount-point.starts-with "/": throw "INVALID_ARGUMENT"
    flash_ = init-sdcard_ mount-point spi-bus.spi_ cs.num 1 max-files allocation-unit-size

  /**
  Mounts an external NOR flash chip on the $spi-bus without formatting the flash.

  The $cs is the chip select pin for the chip on the $spi-bus and $frequency is the SPI frequency.
    $frequency should be one of the FREQUENCY-* constants (such as $FREQUENCY-5MHZ).
  */
  constructor.nor-unformatted
      --.mount-point/string
      --spi-bus/spi.Bus
      --cs/gpio.Pin
      --frequency/int=FREQUENCY-40MHZ:
    if not mount-point.starts-with "/": throw "INVALID_ARGUMENT"
    flash_ = init-nor-flash_ mount-point spi-bus.spi_ cs.num frequency 0 0 0

  /**
  Mounts an external NOR flash chip on the $spi-bus and format the SD-card with $max-files and
    $allocation-unit-size if it is not formatted.

  The $cs is the chip select pin for the chip on the $spi-bus and $frequency is the SPI frequency.
    $frequency should be one of the FREQUENCY-* constants (such as $FREQUENCY-5MHZ).
  */
  constructor.nor
      --.mount-point/string
      --spi-bus/spi.Bus
      --cs/gpio.Pin
      --frequency/int=FREQUENCY-40MHZ
      --max-files/int=5
      --allocation-unit-size/int=16384:
    if not mount-point.starts-with "/": throw "INVALID_ARGUMENT"
    flash_ = init-nor-flash_ mount-point spi-bus.spi_ cs.num frequency 1 max-files allocation-unit-size

  /**
  Mounts an external NAND flash chip on the $spi-bus without formatting the flash.

  The $cs is the chip select pin for the chip on the $spi-bus and $frequency is the SPI frequency.
    $frequency should be one of the FREQUENCY-* constants (such as $FREQUENCY-5MHZ).
  */
  constructor.nand-unformatted
      --.mount-point/string
      --spi-bus/spi.Bus
      --cs/gpio.Pin
      --frequency/int=FREQUENCY-40MHZ:
    if not mount-point.starts-with "/": throw "INVALID_ARGUMENT"

    frequency-mhz := frequency-to-mhz_ frequency
    flash_ = init-nand-flash_ mount-point spi-bus.spi_ cs.num frequency-mhz 0 0 0

  /**
  Mounts an external NAND flash chip on the $spi-bus and formats the flash with $max-files and
     $allocation-unit-size if it is not already formatted.

  The $cs is the chip select pin for the chip on the $spi-bus and $frequency is the SPI frequency.
    $frequency should be one of the FREQUENCY-* constants (such as $FREQUENCY-5MHZ).
  */
  constructor.nand
      --.mount-point/string
      --spi-bus/spi.Bus
      --cs/gpio.Pin
      --frequency/int=FREQUENCY-40MHZ
      --max-files/int=5
      --allocation-unit-size/int=2048:
    if not mount-point.starts-with "/": throw "INVALID_ARGUMENT"

    frequency-mhz := frequency-to-mhz_ frequency
    flash_ = init-nand-flash_ mount-point spi-bus.spi_ cs.num frequency-mhz 1 max-files allocation-unit-size

  /**
  Unmounts and releases resources for the external storage.
  */
  close:
    close-spi-flash_ flash_

frequency-to-mhz_ frequency/int -> int:
  if frequency == FREQUENCY-5MHZ:
    return 5_000_000
  else if frequency == FREQUENCY-10MHZ:
    return 10_000_000
  else if frequency == FREQUENCY-20MHZ:
    return 20_000_000
  else if frequency == FREQUENCY-26MHZ:
    return 80_000_000 / 3
  else if frequency == FREQUENCY-40MHZ:
    return 40_000_000
  else if frequency == FREQUENCY-80MHZ:
    return 80_000_000
  else:
    throw "INVALID_ARGUMENT"

init-nor-flash_ mount-point spi-bus cs frequency format max-files allocation-unit-size -> any:
  #primitive.spi-flash.init-nor-flash

init-nand-flash_ mount-point spi-bus cs frequency format max-files allocation-unit-size -> any:
  #primitive.spi-flash.init-nand-flash

init-sdcard_ mount-point spi-bus cs format max-files allocation-unit-size -> any:
  #primitive.spi-flash.init-sdcard

close-spi-flash_ flash:
  #primitive.spi-flash.close
