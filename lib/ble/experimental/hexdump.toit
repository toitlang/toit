// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.hex

import .transport show Transport

/**
Prints every packet crossing a $Transport as one text line.

Intended for boards, where a serial log is the only channel: each line is
  `HCI <direction> <monotonic microseconds> <hex bytes>` with direction `RX`
  (controller to host) or `TX`. `tools/ble-hci-log.toit` converts such a log
  into a btsnoop file for Wireshark. Printing happens on the transport's own
  tasks and slows the host; keys and application data appear in the output,
  so use it only for diagnosis. Close this transport, not the underlying one.
*/
class Hexdump implements Transport:
  underlying_/Transport
  prefix_/string

  constructor .underlying_ --prefix/string="HCI":
    prefix_ = prefix

  receive -> ByteArray:
    packet := underlying_.receive
    print "$prefix_ RX $Time.monotonic-us $(hex.encode packet)"
    return packet

  send packet/ByteArray -> none:
    underlying_.send packet
    print "$prefix_ TX $Time.monotonic-us $(hex.encode packet)"

  send-if packet/ByteArray [allowed] -> bool:
    sent := underlying_.send-if packet allowed
    if sent: print "$prefix_ TX $Time.monotonic-us $(hex.encode packet)"
    return sent

  close -> none:
    underlying_.close
