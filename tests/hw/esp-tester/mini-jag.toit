// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import esp32
import net
import system.containers
import uuid show Uuid

import .shared

NETWORK-RETRIES ::= 4

main:
  cause := esp32.wakeup-cause
  print "Wakeup cause: $cause"
  // It looks like resetting the chip through the UART yields RST-UNKNOWN.
  if cause == esp32.ESP-RST-POWERON or cause == esp32.ESP-RST-UNKNOWN:
    install-new-test
    esp32.deep-sleep Duration.ZERO
  run-test

install-new-test:
  // Clear all existing containers.
  ids := containers.images.map: | image/containers.ContainerImage |
    image.id
  ids.do: | id/Uuid |
    if id != containers.current:
      containers.uninstall id

  network/net.Client? := null
  for i := 0; i < NETWORK-RETRIES; i++:
    catch --unwind=(: i == NETWORK-RETRIES - 1):
      network = net.open
      break
    sleep (Duration --s=i)
  server-socket := network.tcp-listen 0
  print "$network.address:$server-socket.local-address.port"
  print MINI-JAG-LISTENING
  socket := server-socket.accept
  reader := socket.in
  size := reader.little-endian.read-int32
  expected-crc := reader.read-bytes 4
  summer := crc.Crc32
  print "SIZE: $size"
  writer := containers.ContainerImageWriter size
  written-size := 0
  while written-size < size:
    data := reader.read --max-size=(size - written-size)
    summer.add data
    writer.write data
    written-size += data.size
  print "WRITTEN: $written-size"
  if summer.get != expected-crc:
    throw"CRC MISMATCH"
    return
  writer.commit
  print "INSTALLED CONTAINER"
  print "WAITING FOR RUN-SIGNAL"
  run-message := reader.read-string RUN-TEST.size
  if run-message != RUN-TEST:
    throw"RUN-SIGNAL MISMATCH"
    return
  reader.close
  socket.close
  server-socket.close
  network.close

run-test:
  print "RUNNING INSTALLED CONTAINER"
  containers.images.do: | image/containers.ContainerImage |
    if image.id != containers.current:
      containers.start image.id
