// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import esp32
import expect show *
import io
import net
import system
import system.assets
import system.containers
import system.storage
import net.tcp
import uart
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
    with-control-channel: | reader/io.Reader |
      install-new-test reader
      wait-for-run-signal reader
    esp32.deep-sleep Duration.ZERO
  run-test

with-control-channel [block]:
  control := (assets.decode)[CONTROL-ASSET].to-string
  if control == "serial":
    port := uart.Port.console --large-buffers
    try:
      switch-console-baud-rate port
      print MINI-JAG-LISTENING
      error-monitor := task --background::
        previous-errors := port.errors
        while port.errors == previous-errors:
          sleep --ms=1
        print "$UART-TRANSFER-ERROR: $(port.errors)"
      try:
        block.call port.in
      finally:
        error-monitor.cancel
    finally:
      port.close
  else if control == "network":
    port := uart.Port.console --large-buffers
    try:
      switch-console-baud-rate port
      with-client: | socket/tcp.Socket |
        block.call socket.in
    finally:
      port.close
  else:
    throw "Unknown control channel: $control"

switch-console-baud-rate port/uart.Port:
  // The host switches after flushing its acknowledgement. Give it a short
  // scheduling margin before transmitting at the new rate.
  print "$UART-BAUD-RATE-REQUEST$CONTROL-BAUD-RATE"
  ack := port.in.read-string UART-BAUD-RATE-ACK.size + 1
  if ack != "$UART-BAUD-RATE-ACK\n": throw "BAUD-RATE-ACK MISMATCH"
  sleep --ms=UART-BAUD-RATE-SWITCH-DELAY-MS
  port.baud-rate = CONTROL-BAUD-RATE
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
  arg := reader.read-bytes arg-size
  print "ARGS: $arg.to-string"
  bucket := storage.Bucket.open --ram BUCKET-NAME
  bucket["arg"] = arg.to-string
  bucket.close
  size := reader.little-endian.read-int32
  if size < 0:
    print "ALREADY INSTALLED"
    return
  print "Clearing old containers"
  clear-containers
  print "SIZE: $size"
  expected-crc := reader.read-bytes 4
  summer := crc.Crc32
  // Creating the writer erases the flash region, which can take a while.
  // Only ask for data once that's done: the serial transport has no flow
  // control, so anything sent while we are busy could overflow the
  // receive buffer.
  writer := containers.ContainerImageWriter size
  written-size := 0
  requested := 0
  while written-size < size:
    // Keep only one requested chunk outstanding while writing to flash.
    while requested < size and requested - written-size < CHUNK-SIZE:
      print CHUNK-REQUEST
      requested += min CHUNK-SIZE (size - requested)
    chunk-size := min CHUNK-SIZE (size - written-size)
    data := reader.read-bytes chunk-size
    summer.add data
    writer.write data
    written-size += data.size
  print "WRITTEN: $written-size"
  actual-crc := summer.get
  if actual-crc != expected-crc:
    throw"CRC MISMATCH"
    return
  writer.commit
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
