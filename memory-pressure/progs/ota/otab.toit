// Copyright (C) 2026 Toit contributors.

// The container of the firmware an OTA test updates to (firmware B,
// scripts/ota2.sh): reports the images it finds in flash, starts each
// installed one once more (the boot containers have started already),
// then validates the new firmware (otab-nv.toit: never validates and
// waits for the host to reset the board, which must roll back).

import system
import system.containers
import system.firmware

MARK ::= 0x5a00

run --validate/bool -> none:
  pending := firmware.is-validation-pending
  print "OTA-B new firmware runs ($system.platform), pending $pending"
  mine := []
  containers.images.do: | image/containers.ContainerImage |
    if image.data & 0xff00 == MARK: mine.add image
    print "OTA-B image $image.id name $image.name flags $image.flags data $image.data"
  print "OTA-B $mine.size installed images survive the update"
  // Let the boot containers finish first.
  sleep --ms=3000
  mine.do: | image/containers.ContainerImage |
    code := -1
    start := Time.monotonic-us
    exception := catch: code = (containers.start image.id).wait
    print "OTA-B run data $image.data flags $image.flags: exit $code$(exception ? " $exception" : "") $(Time.monotonic-us - start) us"
  if not validate:
    print "OTA-B not validating; waiting for a reset"
    while true: sleep --ms=1000
  validated := pending and firmware.validate
  print "OTA-B validated $validated"
  print "SUITE done"

main: run --validate
