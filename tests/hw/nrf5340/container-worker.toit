// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import gpio
import system.assets
import system.storage
import expect show *

main arguments:
  payload := assets.decode["payload"]
  expect-bytes-equal (ByteArray 5003: (it * 13 + 9) & 0xff) payload
  bucket := storage.Bucket.open --flash "nrf-containers"
  if arguments is List:
    bucket["boots"] = (bucket.get "boots" --if-absent=: 0) + 1
    print "NRF5340 INSTALLED CONTAINER BOOT"
    return
  if arguments["op"] == "echo":
    bucket["echo"] = arguments["payload"]
    return
  if arguments["op"] == "exit": exit arguments["code"]
  if arguments["op"] == "hold":
    pin := gpio.Pin 8 --output --value=1
    region := storage.Region.open --flash "nrf-container-held" --capacity=4096
    child := spawn::
      child-pin := gpio.Pin 9 --output --value=1
      while true: sleep --ms=100
    while true: sleep --ms=100
  throw "Unknown worker operation"
