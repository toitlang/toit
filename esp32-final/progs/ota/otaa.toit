// Copyright (C) 2026 Toit contributors.

// The container of the firmware an OTA test starts from (firmware A,
// scripts/ota2.sh). On the first boot it installs the images of its assets
// in flash with FLAG-RUN-BOOT (names u-*: untrusted, else trusted), starts
// each once, then downloads the new firmware from the host (a 4-byte
// little-endian size, then the bytes), writes it with system.firmware and
// reboots into it. When the images are already installed (firmware A runs
// again after a rollback) it only reports them; the system starts them as
// boot containers.

import io
import net
import net.tcp
import system
import system.assets
import system.containers
import system.firmware

HOST ::= "192.168.77.248"
PORT ::= 7999
MARK ::= 0x5a00

report tag/string -> List:
  mine := []
  containers.images.do: | image/containers.ContainerImage |
    if image.data & 0xff00 == MARK: mine.add image
    print "$tag image $image.id name $image.name flags $image.flags data $image.data"
  return mine

memory name/string -> none:
  stats := system.process-stats
  print "MEM $name system-free $stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest $stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]"

main:
  print "OTA-A firmware A runs ($system.platform), pending $firmware.is-validation-pending"
  mine := report "OTA-A"
  if not mine.is-empty:
    print "OTA-A again: $mine.size installed images present (rollback or repeated boot)"
    sleep --ms=4000
    print "SUITE done"
    return
  decoded := assets.decode
  index := 0
  ids := {:}
  decoded.keys.sort.do: | name/string |
    image/ByteArray := decoded[name]
    index++
    id := null
    start := Time.monotonic-us
    exception := catch:
      writer := containers.ContainerImageWriter image.size
      try:
        List.chunk-up 0 image.size 4096: | from to | writer.write image[from..to]
        id = writer.commit --data=(MARK + index) --run-boot --untrusted=(name.starts-with "u-")
      finally:
        writer.close
    print "OTA-A install $name: $(id ? "ok $id" : "failed $exception") $(Time.monotonic-us - start) us"
    if id: ids[name] = id
  ids.do: | name/string id |
    code := -1
    exception := catch: code = (containers.start id).wait
    print "OTA-A run $name: exit $code$(exception ? " $exception" : "")"
  report "OTA-A installed"
  memory "before-ota"
  network := net.open
  socket/tcp.Socket := network.tcp-connect HOST PORT
  reader := socket.in
  size := io.LITTLE-ENDIAN.uint32 (reader.read-bytes 4) 0
  print "OTA-A download $size bytes"
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
    writer.commit
  finally:
    writer.close
    socket.close
    network.close
  print "OTA-A upgrading"
  firmware.upgrade
