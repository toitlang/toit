// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Converts a serial log with `ble.experimental.hexdump` lines into a btsnoop file.

Usage: `toit run tools/ble-hci-log.toit LOG OUT.btsnoop [PREFIX]`

Lines of the form `PREFIX RX|TX <microseconds> <hex>` become records with
  data link 1002 (HCI H4, packet-type byte included), which Wireshark and
  btmon open. Other lines are ignored. Timestamps are the board's monotonic
  clock, offset so the first packet lands at the file's creation time.
*/

import encoding.hex
import host.file
import io

main args/List:
  if args.size < 2 or args.size > 3:
    print "Usage: ble-hci-log.toit LOG OUT.btsnoop [PREFIX]"
    exit 1
  prefix := args.size == 3 ? args[2] : "HCI"
  input := (file.read-contents args[0]).to-string
  out := file.Stream.for-write args[1]
  writer := out.out
  writer.write #['b', 't', 's', 'n', 'o', 'o', 'p', 0, 0, 0, 0, 1, 0, 0, 0x03, 0xea]
  epoch-offset := 0x00dc_ddb3_0f2f_8000
  base/int? := null
  now := Time.now.ns-since-epoch / 1000
  count := 0
  (input.split "\n").do: | line/string |
    parts := (line.trim).split " "
    if parts.size != 4 or parts[0] != prefix: continue.do
    if parts[1] != "RX" and parts[1] != "TX": continue.do
    stamp := int.parse parts[2] --if-error=: continue.do
    packet := hex.decode parts[3]
    if packet.is-empty: continue.do
    if base == null: base = stamp
    record := ByteArray 24
    io.BIG-ENDIAN.put-uint32 record 0 packet.size
    io.BIG-ENDIAN.put-uint32 record 4 packet.size
    flags := (parts[1] == "RX" ? 1 : 0) | ((packet[0] == 1 or packet[0] == 4) ? 2 : 0)
    io.BIG-ENDIAN.put-uint32 record 8 flags
    io.BIG-ENDIAN.put-int64 record 16 (now + (stamp - base) + epoch-offset)
    writer.write record
    writer.write packet
    count++
  out.close
  print "wrote $count packets to $args[1]"
