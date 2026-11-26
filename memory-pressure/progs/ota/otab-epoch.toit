// Copyright (C) 2026 Toit contributors.

// Firmware B of the verification-epoch scenario (esp32-final): a firmware
// whose verification epoch differs from firmware A's. Reports the images it
// finds in flash, starts each installed one once more (the untrusted one
// must be refused: its verdict is of A's epoch), then reinstalls every
// untrusted image that was refused from the same assets (verified now, by
// B) and starts it again, and validates the new firmware.

import system
import system.assets
import system.containers
import system.firmware

MARK ::= 0x5a00

run-image image/containers.ContainerImage tag/string -> int:
  code := -1
  start := Time.monotonic-us
  exception := catch: code = (containers.start image.id).wait
  print "OTA-B $tag data $image.data flags $image.flags: exit $code$(exception ? " $exception" : "") $(Time.monotonic-us - start) us"
  return exception ? -1 : code

main:
  pending := firmware.is-validation-pending
  print "OTA-B new firmware runs ($system.platform), pending $pending"
  mine := []
  containers.images.do: | image/containers.ContainerImage |
    if image.data & 0xff00 == MARK: mine.add image
    print "OTA-B image $image.id name $image.name flags $image.flags data $image.data"
  print "OTA-B $mine.size installed images survive the update"
  // Let the boot containers finish first.
  sleep --ms=3000
  refused := []
  mine.do: | image/containers.ContainerImage |
    if (run-image image "run") < 0: refused.add image
  decoded := assets.decode
  names := decoded.keys.sort
  refused.do: | image/containers.ContainerImage |
    // The assets are installed in name order with data MARK + 1, + 2, ...
    index := (image.data & 0xff) - 1
    if not 0 <= index < names.size: continue.do
    name/string := names[index]
    if not name.starts-with "u-":
      print "OTA-B not reinstalling $name (trusted)"
      continue.do
    catch: containers.uninstall image.id
    bytes/ByteArray := decoded[name]
    id := null
    start := Time.monotonic-us
    exception := catch:
      writer := containers.ContainerImageWriter bytes.size
      try:
        List.chunk-up 0 bytes.size 4096: | from to | writer.write bytes[from..to]
        id = writer.commit --data=image.data --run-boot --untrusted
      finally:
        writer.close
    print "OTA-B reinstall $name: $(id ? "ok $id" : "failed $exception") $(Time.monotonic-us - start) us"
    if id:
      code := -1
      run-start := Time.monotonic-us
      run-exception := catch: code = (containers.start id).wait
      print "OTA-B run reinstalled $name: exit $code$(run-exception ? " $run-exception" : "") $(Time.monotonic-us - run-start) us"
  validated := pending and firmware.validate
  print "OTA-B validated $validated"
  print "SUITE done"
