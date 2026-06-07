// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import esp32
import expect show *
import io
import net
import net.tcp
import system show architecture
import system.containers
import system.storage
import uuid show Uuid

// EC618-only dependencies. Importing them on the ESP32 is harmless; the
// EC618 code path is the only one that actually calls into them.
import ec618
import ec618.slot
import ec618.watchdog
import system.firmware
import uart

import .shared

NETWORK-RETRIES ::= 10
BUCKET-NAME ::= "toitlang.org/toit/tester"

main:
  // The EC618 has neither Wi-Fi nor a host reset line in our rig, so it runs a
  // resident agent that talks the whole control protocol over its print UART.
  // Every other (ESP32) target keeps the original Wi-Fi/TCP control channel.
  if architecture == "ec618":
    main-ec618
    return

  cause := esp32.wakeup-cause
  print "Wakeup cause: $cause"
  // It looks like resetting the chip through the UART yields RESET-UNKNOWN.
  if cause == esp32.RESET-POWER-ON or cause == esp32.RESET-UNKNOWN:
    // This check isn't necessary, but is hard to test within our tests.
    // It just makes sure that the run-time is properly reset when the device is
    // powered on through a reset.
    expect esp32.total-run-time < 500_000  // 0.5s
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

// ----------------------------------------------------------------------------
// EC618 resident agent.
//
// The agent owns the print UART (whichever controller the firmware redirects
// `print` to) and serves the request/ack protocol from $shared. It never
// reboots itself: a test runs as a child container whose `print` output streams
// back on the same wire, and once it exits the agent loops back to listening —
// ready for the next test or a firmware OTA. See shared.toit for the wire
// format.

// Opens the UART the firmware redirects `print` to, so the agent's control
// channel and the test's print output ride one wire. Which controller that is
// depends on CONFIG_TOIT_EC618_PRINT_UART_ID; we follow it rather than
// hardcoding, so a rig that breaks out a different UART only needs the build
// config changed (test rig uses UART0, the quirky-plenty dev rig uses UART1).
open-control-uart -> uart.Port:
  id := ec618.print-uart-id
  if id == 0: return ec618.Ec618.uart0 --baud-rate=115200
  if id == 1: return ec618.Ec618.uart1 --baud-rate=115200
  if id == 2: return ec618.Ec618.uart2 --baud-rate=115200
  throw "mini-jag needs a print UART (build with CONFIG_TOIT_EC618_PRINT_UART=1)"

main-ec618:
  port := open-control-uart
  reader := port.in
  out := port.out
  reason := ec618.reset-reason-name ec618.reset-reason
  status out "ec618 ready reset=$reason active=$(string.from-rune slot.active)"
  // The host's running firmware writer survives across commands.
  writer/firmware.FirmwareWriter? := null
  arg/string := ""
  while true:
    command := reader.read-byte
    if command == CMD-PING:
      out.write #[ACK-PONG]
    else if command == CMD-ARG:
      size := reader.little-endian.read-int32
      arg = (reader.read-bytes size).to-string
      status out "arg=\"$arg\""
      out.write #[ACK-OK]
    else if command == CMD-INSTALL:
      out.write #[(install-container reader out ? ACK-OK : ACK-ERROR)]
    else if command == CMD-RUN:
      run-installed arg out
    else if command == CMD-FW-BEGIN:
      size := reader.little-endian.read-int32
      error := catch: writer = firmware.FirmwareWriter 0 size
      status out "fw begin size=$size$(error ? " error=$error" : "")"
      out.write #[(error ? ACK-ERROR : ACK-OK)]
    else if command == CMD-FW-WRITE:
      out.write #[(fw-write reader writer out ? ACK-OK : ACK-ERROR)]
    else if command == CMD-FW-COMMIT:
      checksum := reader.read-bytes 32
      error := catch: writer.commit --checksum=checksum
      writer = null
      status out "fw commit$(error ? " error=$error" : " ok")"
      out.write #[(error ? ACK-ERROR : ACK-OK)]
    else if command == CMD-FW-UPGRADE:
      status out "fw upgrade: rebooting into the trial slot"
      out.write #[ACK-OK]
      firmware.upgrade  // Does not return — the device reboots.
    else if command == CMD-TRIAL:
      out.write #[(firmware.is-validation-pending ? ACK-TRIAL-YES : ACK-TRIAL-NO)]
    else if command == CMD-VALIDATE:
      error := catch: firmware.validate
      status out "validate$(error ? " error=$error" : " ok")"
      out.write #[(error ? ACK-ERROR : ACK-OK)]
    else if command == CMD-ROLLBACK:
      status out "rollback: resetting to the known-good slot"
      out.write #[ACK-OK]
      firmware.rollback  // Does not return — the device reboots.
    else:
      // A stray byte (boot-rom noise, a half-consumed command). Report it and
      // resync on the next byte; the host re-pings to recover.
      status out "ignoring 0x$(%02x command)"

// Writes one `[mini-jag] ...` status line to the host. The agent uses these
// for all of its own chatter; the host prints them and otherwise ignores any
// '['-led line, which is how it tells status text from a single ack byte.
status out/io.Writer message/string -> none:
  out.write "$MINI-JAG-TAG $message\n"

// Receives a container image and installs it, clearing any previously
// installed test first. Returns whether it succeeded (the caller writes the
// final ack from the result).
//
// Wire format: `<size:4 LE><crc32:4>` then, after ACK-READY, a sequence of
// `<len:4 BE><bytes>` chunks each acked with ACK-OK. The per-chunk ack
// flow-controls the transfer: the shared UART has no hardware flow control and
// the device RX buffer is small, so the host waits for each chunk to reach
// flash before sending the next.
install-container reader/io.Reader out/io.Writer -> bool:
  size := reader.little-endian.read-int32
  expected-crc := reader.read-bytes 4
  clear-containers
  summer := crc.Crc32
  image-writer := containers.ContainerImageWriter size
  out.write #[ACK-READY]
  written := 0
  error := catch:
    while written < size:
      length := reader.big-endian.read-uint32
      chunk := reader.read-bytes length
      summer.add chunk
      image-writer.write chunk
      written += chunk.size
      out.write #[ACK-OK]
    if summer.get != expected-crc: throw "CRC mismatch"
    image-writer.commit
  status out "install size=$size written=$written$(error ? " error=$error" : " ok")"
  return error == null

// The hardware watchdog tops out at 60s (see ec618.watchdog), so to give a test
// a few minutes we arm it short and keep feeding it from a task until either the
// test finishes or the overall budget runs out.
TEST-WATCHDOG-BUDGET ::= Duration --m=3
WATCHDOG-HARDWARE-TIMEOUT ::= Duration --s=10
WATCHDOG-FEED-INTERVAL ::= Duration --s=3

// Starts the installed test container and waits for it to exit. Its `print`
// output streams to the host over the same UART while we wait; the host watches
// that stream for the test's own completion marker.
//
// A test runs under the hardware watchdog so a hang or a crash recovers the
// device on its own. The watchdog is armed and fed from a separate task for up
// to $TEST-WATCHDOG-BUDGET. If the test exits first we stop the watchdog; if it
// hangs past the budget — or wedges the whole device, taking the feeder task
// down with it — the watchdog resets the chip, which reboots straight back into
// this agent. No external reset needed.
run-installed arg/string out/io.Writer -> none:
  test-image/containers.ContainerImage? := null
  containers.images.do: | image/containers.ContainerImage |
    if not test-image and image.id != containers.current: test-image = image
  if not test-image:
    status out "run: no container installed"
    return
  status out "run: starting test (watchdog budget $(TEST-WATCHDOG-BUDGET.in-s)s)"
  watchdog.watchdog-start --timeout=WATCHDOG-HARDWARE-TIMEOUT
  feeder := task:: feed-watchdog out
  try:
    container := containers.start test-image.id [arg]
    code := container.wait
    status out "run: test exited code=$code"
  finally:
    feeder.cancel
    watchdog.watchdog-stop

// Feeds the hardware watchdog every $WATCHDOG-FEED-INTERVAL for up to
// $TEST-WATCHDOG-BUDGET, then stops so the watchdog fires. Runs as its own task
// (cancelled once the test exits) so a busy or hung test container can neither
// keep it from feeding within budget nor from giving up past it.
feed-watchdog out/io.Writer -> none:
  deadline := Time.monotonic-us + TEST-WATCHDOG-BUDGET.in-us
  while Time.monotonic-us < deadline:
    watchdog.watchdog-feed
    sleep WATCHDOG-FEED-INTERVAL
  status out "run: watchdog budget elapsed; letting the device reset"

// Reads one OTA chunk (`<len:4 BE><bytes>`) and feeds it to the firmware
// $writer. Acks ready before the payload so the host paces the transfer.
fw-write reader/io.Reader writer/firmware.FirmwareWriter? out/io.Writer -> bool:
  length := reader.big-endian.read-uint32
  out.write #[ACK-READY]
  chunk := reader.read-bytes length
  if not writer:
    status out "fw write: no active writer"
    return false
  error := catch: writer.write chunk
  if error: status out "fw write error=$error"
  return error == null
