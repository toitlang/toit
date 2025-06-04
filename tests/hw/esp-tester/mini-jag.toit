// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import esp32
import expect show *
import io
import net
import system.containers
import system.storage
import net.tcp
import uuid show Uuid

import .shared

NETWORK-RETRIES ::= 10
BUCKET-NAME ::= "toitlang.org/toit/tester"

main:
  cause := esp32.wakeup-cause
  print "Wakeup cause: $cause"
  // It looks like resetting the chip through the UART yields RESET-UNKNOWN.
  if cause == esp32.RESET-POWER-ON or cause == esp32.RESET-UNKNOWN:
    // This check isn't necessary, but is hard to test within our tests.
    // It just makes sure that the run-time is properly reset when the device is
    // powered on through a reset.
    expect esp32.total-run-time < 500_000  // 0.5s
    print "Clearing containers and waiting for new test"
    clear-containers
    with-client: | socket/tcp.Socket |
      install-new-test socket.in
      wait-for-run-signal socket.in
    esp32.deep-sleep Duration.ZERO
  run-test

with-client [block]:
  network/net.Client? := null
  for i := 0; i < NETWORK-RETRIES; i++:
    catch --unwind=(: i == NETWORK-RETRIES - 1):
      network = net.open
      break
    sleep (Duration --s=1)
  if not network: throw "Failed to open network"
  server-socket := network.tcp-listen 0
  print "$network.address:$server-socket.local-address.port"
  print MINI-JAG-LISTENING
  socket := server-socket.accept
  try:
    block.call socket
  finally:
    socket.close
    server-socket.close
    network.close

clear-containers:
  ids := containers.images.map: | image/containers.ContainerImage |
    image.id
  ids.do: | id/Uuid |
    if id != containers.current:
      containers.uninstall id

install-new-test reader/io.Reader:
  arg-size := reader.little-endian.read-int32
  if arg-size < 0:
    print "ALREADY INSTALLED"
    return
  arg := reader.read-bytes arg-size
  print "ARGS: $arg.to-string"
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
  actual-crc := summer.get
  if actual-crc != expected-crc:
    throw"CRC MISMATCH"
    return
  writer.commit
  bucket := storage.Bucket.open --ram BUCKET-NAME
  bucket["arg"] = arg.to-string
  bucket.close
  print INSTALLED-CONTAINER

wait-for-run-signal reader/io.Reader:
  print "WAITING FOR RUN-SIGNAL"
  run-message := reader.read-string RUN-TEST.size
  if run-message != RUN-TEST:
    throw "RUN-SIGNAL MISMATCH"
    return

run-test:
  print RUNNING-CONTAINER
  bucket := storage.Bucket.open --ram BUCKET-NAME
  arg := bucket["arg"]
  bucket.close
  containers.images.do: | image/containers.ContainerImage |
    if image.id != containers.current:
      containers.start image.id [arg]
