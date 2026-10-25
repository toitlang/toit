// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import gpio
import zephyr
import system.assets
import system.containers
import system.storage
import uuid show Uuid
import expect show *
import ...containers-test as common

main arguments:
  if arguments is Map:
    common.main-child arguments
    return
  ack := gpio.Pin 33 --input --pull-down
  phase-pin := gpio.Pin 32 --input
  phase := phase-pin.get
  phase-pin.close
  sleep --ms=100
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  bytes := assets.decode["worker.image"]
  id := Uuid bytes[12..28]
  bucket := storage.Bucket.open --flash "nrf-containers"
  if phase == 0:
    expect-equals "PRIVILEGED_PRIMITIVE" (catch: privileged-flash-size 0)
    containers.uninstall id
    bucket.remove "echo"
    bucket["boots"] = 0
    common.test-images
    common.test-start
    common.test-background-state-changed
    print "CONTAINERS bundled image, start/wait and events PASS"

    // Interrupted uploads must release their reservations without publishing.
    8.repeat:
      writer := containers.ContainerImageWriter bytes.size
      writer.write bytes[..131]
      writer.close
    writer := containers.ContainerImageWriter bytes.size
    writer.write bytes[..7]
    expect-equals "Incomplete image" (catch: writer.commit)
    writer.close
    expect-equals 1 containers.images.size
    installed := install bytes --no-run-boot
    expect-equals id installed
    image := (containers.images.filter: it.id == id).first
    expect-equals 0x80 image.flags
    expect-equals 0x1234_5678 image.data
    print "CONTAINERS partial uploads, streamed relocation and assets PASS"

    payload := ByteArray 1027: (it * 7 + 1) & 0xff
    worker := containers.start id {"op": "echo", "payload": payload}
    expect-equals 0 worker.wait
    expect-bytes-equal payload bucket["echo"]
    worker = containers.start id {"op": "exit", "code": 7}
    expect-equals 7 worker.wait

    request.call "CONFIG 18 DOWN 0"
    request.call "CONFIG 23 DOWN 0"
    worker = containers.start id {"op": "hold"}
    request.call "WAIT 18 1"
    request.call "WAIT 23 1"
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 8 --output)
    expect-equals "ALREADY_IN_USE" (catch: storage.Region.open --flash "nrf-container-held")
    expect-equals 0 worker.stop
    request.call "CHECK 18 0"
    request.call "CHECK 23 0"
    pin := gpio.Pin 8 --output
    pin.close
    pin = gpio.Pin 9 --output
    pin.close
    region := storage.Region.open --flash "nrf-container-held"
    region.close
    storage.Region.delete --flash "nrf-container-held"
    print "CONTAINERS exit status, process tree stop and resource cleanup PASS"

    containers.uninstall id
    expect-equals 1 containers.images.size
    expect-not-null (catch: containers.start id)
    expect-equals id (install bytes --run-boot)
    request.call "CONFIG 13 OUT 1"
    print "CONTAINERS reboot with installed auto-start image"
    zephyr.reset
    throw "reset returned"

  expect (zephyr.reset-reason & zephyr.RESET-SOFTWARE != 0)
  with-timeout --ms=5000:
    while bucket["boots"] != 1: sleep --ms=10
  expect-equals 2 containers.images.size
  worker := containers.start id {"op": "echo", "payload": "after reset"}
  expect-equals 0 worker.wait
  expect-equals "after reset" bucket["echo"]
  containers.uninstall id
  expect-equals 1 containers.images.size
  bucket.close
  print "CONTAINERS installed image auto-start and uninstall PASS"
  indicator := gpio.Pin 8 --output --value=1
  request.call "WAIT 18 1"
  print "NRF5340 CONTAINERS PASS"

install bytes/ByteArray --run-boot/bool -> Uuid:
  writer := containers.ContainerImageWriter bytes.size
  try:
    sizes := [1, 7, 131, 132, 133, 511, 1024]
    offset := 0
    sequence := 0
    while offset < bytes.size:
      end := min bytes.size (offset + sizes[sequence++ % sizes.size])
      writer.write bytes[offset..end]
      offset = end
    return writer.commit --run-boot=run-boot --data=0x1234_5678
  finally:
    writer.close

privileged-flash-size offset/int -> int:
  #primitive.flash.get-size
