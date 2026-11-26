// Copyright (C) 2026 Toit contributors.

// OTA without Jaguar: downloads a firmware binary from the host over TCP
// (scripts/ota.sh: a 4-byte little-endian size, then the bytes), writes it
// with system.firmware's writer and reboots into it. The new firmware's
// container (hwota-after) validates it.

import io
import net
import net.tcp
import system.firmware

HOST ::= "192.168.77.248"
PORT ::= 7999

main:
  print "OTA running, validation pending: $firmware.is-validation-pending"
  network := net.open
  socket/tcp.Socket := network.tcp-connect HOST PORT
  reader := socket.in
  size := io.LITTLE-ENDIAN.uint32 (reader.read-bytes 4) 0
  print "OTA size $size"
  start := Time.monotonic-us
  writer := firmware.FirmwareWriter 0 size
  written := 0
  try:
    while written < size:
      data := reader.read
      if not data: throw "OTA: connection closed at $written"
      writer.write data
      written += data.size
    print "TIME ota-download-and-write $(Time.monotonic-us - start) us bytes $written"
    commit-start := Time.monotonic-us
    writer.commit
    print "TIME ota-commit $(Time.monotonic-us - commit-start) us"
  finally:
    writer.close
    socket.close
    network.close
  print "OTA upgrading"
  firmware.upgrade
