// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import spi

REG-COMMAND ::= 0x01
REG-FIFO-DATA ::= 0x09
REG-FIFO-LEVEL ::= 0x0a
REG-VERSION ::= 0x37

COMMAND-IDLE ::= 0x00
FIFO-FLUSH ::= 0b1000_0000

read-reg device/spi.Device register/int -> int:
  data := ByteArray 2
  data[0] = (register << 1) | 0x80
  device.transfer data --read
  return data[1]

write-reg device/spi.Device register/int value/int -> none:
  device.transfer #[(register << 1) & 0x7e, value]

write-fifo device/spi.Device bytes/ByteArray -> none:
  bytes.do: write-reg device REG-FIFO-DATA it

read-fifo device/spi.Device count/int -> ByteArray:
  return ByteArray count: read-reg device REG-FIFO-DATA

// Writes all $bytes into the FIFO in one transfer. The MFRC522 retains the
// FIFO register address for every byte that follows it.
write-fifo-burst device/spi.Device bytes/ByteArray -> none:
  data := ByteArray bytes.size + 1
  data[0] = (REG-FIFO-DATA << 1) & 0x7e
  data.replace 1 bytes
  device.transfer data

// Reads $count FIFO bytes in one full-duplex transfer. Every MOSI byte but
// the last repeats the read address; MISO bytes from index 1 carry FIFO data.
read-fifo-burst device/spi.Device count/int -> ByteArray:
  data := ByteArray count + 1: (REG-FIFO-DATA << 1) | 0x80
  data[count] = 0
  device.transfer data --read
  return data[1..]
