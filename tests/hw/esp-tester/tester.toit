// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import crypto.crc
import crypto.sha256 show sha256
import fs
import host.directory
import host.file
import host.os
import host.pipe
import io
import monitor
import net
import net.tcp
import system
import uart
import .shared

CHIP-ESP32 ::= "esp32"
CHIP-EC618 ::= "ec618"

ALL-TESTS-DONE ::= "All tests done"
JAG-DECODE ::= "jag decode"

start-time-us/int := ?

// All tester output is ALSO appended to this file (opened at startup), so device
// output — including exceptions, crashes and boot banners the device prints
// during a run — is always captured for inspection even when stdout isn't being
// watched. Everything the tester emits, and every device line it reads, funnels
// through $log, so teeing $log here captures it all. Override the path with the
// TESTER_LOG env var.
TESTER-LOG-ENV_ ::= "TESTER_LOG"
TESTER-LOG-DEFAULT_ ::= "/tmp/ec618-tester.log"
log-file_/file.Stream? := null

open-log-file_ -> none:
  path := os.env.get TESTER-LOG-ENV_
  if not path or path == "": path = TESTER-LOG-DEFAULT_
  catch --trace:
    // O_WRONLY|O_APPEND|O_CREAT, mode 0644. write() is a syscall (no userspace
    // buffering), so the file holds everything up to a crash.
    log-file_ = file.Stream path (file.WRONLY | file.APPEND | file.CREAT) 0x1a4
    log-file_.out.write "\n===== tester run =====\n"

log message/string:
  duration := Duration --us=(Time.monotonic-us - start-time-us)
  lines := message.split "\n"
  lines.do:
    line := "--- $(%06d duration.in-ms): $it"
    print_ line
    if log-file_: catch: log-file_.out.write "$line\n"

main args:
  start-time-us = Time.monotonic-us
  open-log-file_
  root-cmd := cli.Command "tester"
      --help="Run tests on an ESP tester"
      --options=[
        cli.Option "toit-exe"
            --help="The path to the Toit executable"
            --type="path"
            --required,
      ]

  setup-cmd := cli.Command "setup"
      --help="Setup the tester (mini-jag firmware) on the device"
      --options=[
        cli.OptionEnum "chip" [CHIP-ESP32, CHIP-EC618]
            --help="The target chip. EC618 skips Wi-Fi and flashes over the boot ROM."
            --default=CHIP-ESP32,
        cli.Option "toit-exe"
            --help="The path to the Toit executable"
            --type="path"
            --required,
        cli.Option "port"
            --help="The path to the UART port"
            --type="path"
            --required,
        cli.Option "envelope"
            --help="The path to the envelope"
            --type="path"
            --required,
        cli.Option "wifi-ssid"
            --help="The WiFi SSID (ESP32 only)"
            --type="string",
        cli.Option "wifi-password"
            --help="The WiFi password (ESP32 only)"
            --type="string",
      ]
      --run=:: | invocation/cli.Invocation |
        if invocation["chip"] == CHIP-EC618:
          setup-tester-ec618 invocation
        else:
          setup-tester invocation

  root-cmd.add setup-cmd

  run-cmd := cli.Command "run"
      --help="Run a test on the ESP"
      --options=[
        cli.OptionEnum "chip" [CHIP-ESP32, CHIP-EC618]
            --help="The target chip. The EC618 talks the control protocol over the serial port (no Wi-Fi)."
            --default=CHIP-ESP32,
        cli.Option "port-board1"
            --help="The path to the UART port of board 1"
            --type="path"
            --required,
        cli.Option "port-board2"
            --help="The path to the UART port of board 2"
            --type="path",
        cli.Option "arg"
            --help="The argument to pass to the test"
            --type="string"
            --default="",
        cli.Flag "flaky"
            --help="Run the test in flaky mode, which will retry on failure"
            --default=false,
      ]
      --rest=[
        cli.Option "test"
            --help="The path to the code for board 1"
            --type="path"
            --required,
        cli.Option "test2"
            --help="The path to the code for board 2"
            --type="path",
      ]
      --run=:: | invocation/cli.Invocation |
        if invocation["chip"] == CHIP-EC618:
          run-test-ec618 invocation
        else:
          run-test invocation
  root-cmd.add run-cmd

  firmware-update-cmd := cli.Command "firmware-update"
      --help="""
        Update the firmware over the air (EC618 only).

        Builds the canonical firmware image from the envelope (with the mini-jag
        agent embedded), streams it to the running agent over the serial port,
        which writes it to the inactive VM slot, reboots into it on trial, and —
        unless --no-validate — confirms it."""
      --options=[
        cli.Option "toit-exe"
            --help="The path to the Toit executable"
            --type="path"
            --required,
        cli.Option "port"
            --help="The path to the UART port"
            --type="path"
            --required,
        cli.Option "envelope"
            --help="The path to the new firmware envelope to OTA"
            --type="path"
            --required,
        cli.Flag "validate"
            --help="Validate the trial slot after it boots (else it rolls back on the next reset)"
            --default=true,
        cli.Flag "debug-boot"
            --help="Log the raw console for a few seconds after the upgrade reboot (to debug a trial slot that never reconnects)"
            --default=false,
      ]
      --run=:: | invocation/cli.Invocation |
        firmware-update invocation
  root-cmd.add firmware-update-cmd

  root-cmd.run args

with-tmp-dir [block]:
  dir := directory.mkdtemp "/tmp/esp-tester"
  try:
    block.call dir
  finally:
    directory.rmdir --recursive dir

run-toit toit-exe/string args/List --ui/cli.Ui:
  ui.emit --verbose "Running $toit-exe $args."
  exit-code := pipe.run-program [toit-exe] + args
  if exit-code != 0:
    throw "Failed to run Toit"

run-test invocation/cli.Invocation:
  ui := invocation.cli.ui
  toit-exe := invocation["toit-exe"]
  port-board1 := invocation["port-board1"]
  port-board2 := invocation["port-board2"]
  test-path := invocation["test"]
  test2-path := invocation["test2"]
  arg := invocation["arg"]
  flaky := invocation["flaky"]

  already-installed := false
  attempts := flaky ? 3 : 1
  attempts.repeat: | attempt/int |
    print "\n"
    log "Attempt $(attempt + 1) of $attempts"
    // If we didn't manage to install the test something went wrong.
    catch --unwind=(: not already-installed or attempt == attempts - 1):
      board1 := TestDevice
          --name="board1"
          --port-path=port-board1
          --ui=ui
          --toit-exe=toit-exe
          --already-installed=already-installed
      board2/TestDevice? := null

      try:
        board1-ready := monitor.Latch

        task::
          image/ByteArray? := null
          Task.group [
            :: board1.connect-network,
            :: image = board1.compile-test test-path,
          ]
          board1.install-test image arg
          log "Board1 ready"
          board1-ready.set true

        if port-board2:
          board2 = TestDevice
              --name="board2"
              --port-path=port-board2
              --ui=ui
              --toit-exe=toit-exe
              --already-installed=already-installed
          image2/ByteArray? := null
          Task.group [
            :: board2.connect-network,
            :: image2 = board2.compile-test test2-path,
          ]
          board2.install-test image2 arg
          log "Board2 ready"

        board1-ready.get
        already-installed = true

        board1.run-test
        if port-board2:
          board1.running-container.get
          board2.run-test

        ui.emit --verbose "Waiting for all tests to be done."
        board1.all-tests-done.get
        log "Board1 done"
        if board2:
          board2.all-tests-done.get
          log "Board2 done"

        // Success. No need to run another attempt.
        return
      finally:
        board1.close
        if board2: board2.close

class TestDevice:
  static SNAPSHOT-NAME ::= "test.snap"
  name/string
  port/uart.HostPort? := ?
  toit-exe/string
  // Whether the test has already been installed on the device.
  already-installed/bool
  read-task/Task? := null
  is-active/bool := false
  collected-output/string := ""
  ready-latch/monitor.Latch := monitor.Latch
  installed-container/monitor.Latch := monitor.Latch
  running-container/monitor.Latch := monitor.Latch
  all-tests-done/monitor.Latch := monitor.Latch
  ui/cli.Ui
  tmp-dir/string

  network_/net.Client? := null
  socket_/tcp.Socket? := null

  constructor --.name --.toit-exe --port-path/string --.ui --.already-installed:
    port = uart.HostPort port-path --baud-rate=115200
    tmp-dir = directory.mkdtemp "/tmp/esp-tester"
    read-task = task --background::
      try:
        reader := port.in
        stdout := pipe.stdout
        at-new-line := true
        while data/ByteArray? := reader.read:
          if not is-active: continue
          data-str := data.to-string-non-throwing
          if at-new-line: data-str = "\n$data-str"
          if data-str.ends-with "\n":
            at-new-line = true
            data-str = data-str[.. data-str.size - 1]
          else:
            at-new-line = false
          timestamp := Duration --us=(Time.monotonic-us - start-time-us)
          stdout-text := data-str.replace --all "\n" "\n$(%06d timestamp.in-ms)-$name: "
          stdout.out.write stdout-text
          collected-output += data-str
          if collected-output.contains "\n$MINI-JAG-LISTENING": set-latch_ ready-latch
          if collected-output.contains "\n$ALL-TESTS-DONE": set-latch_ all-tests-done
          if collected-output.contains "\n$INSTALLED-CONTAINER": set-latch_ installed-container
          if collected-output.contains "\n$RUNNING-CONTAINER": set-latch_ running-container
          if collected-output.contains JAG-DECODE:
            if file.is-file "$tmp-dir/$SNAPSHOT-NAME":
              // Otherwise it's probably an error during setup.
              index := collected-output.index-of JAG-DECODE
              new-line := collected-output.index-of "\n" index
              if new-line < 0:
                // Wait for more data.
                continue
              line := collected-output[index + JAG-DECODE.size..new-line].trim
              snapshot-path := "$tmp-dir/$SNAPSHOT-NAME"
              toit_ ["decode", "-s", snapshot-path, line]
            all-tests-done.set --exception "Error detected"

      finally:
        read-task = null
        if port:
          port.close
          port = null

  set-latch_ latch/monitor.Latch:
    if latch.has-value: return
    latch.set true

  close:
    if read-task:
      read-task.cancel
    if file.is-directory tmp-dir:
      directory.rmdir --recursive tmp-dir
    disconnect-network

  toit_ args/List:
    run-toit toit-exe args --ui=ui

  connect-network:
    log "Connecting to $name"
    // Reset the device.
    ui.emit --verbose "Resetting $name."
    port.set-control-flag uart.HostPort.CONTROL-FLAG-DTR false
    port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS true
    is-active = true
    sleep --ms=500
    port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS false

    ui.emit --verbose "Waiting for $name to be ready."
    ready-latch.get
    ui.emit --verbose "Device $name is ready."

    lines/List := collected-output.split "\n"
    lines.map --in-place: it.trim
    listening-line-index := lines.index-of --last MINI-JAG-LISTENING
    host-port-line := lines[listening-line-index - 1]
    parts := host-port-line.split ":"
    network_ = net.open
    socket_ = network_.tcp-connect parts[0] (int.parse parts[1])
    ui.emit --info "Connected to $host-port-line."

  disconnect-network:
    if socket_: socket_.close
    socket_ = null
    if network_: network_.close
    network_ = null

  compile-test test-path -> ByteArray:
    if already-installed:
      log "Skipping compilation, already installed"
      return #[]
    log "Compiling test"
    snapshot-path := "$tmp-dir/$SNAPSHOT-NAME"
    toit_ [
      "compile",
      "--snapshot",
      "-o", snapshot-path,
      test-path
    ]

    log "Converting snapshot to image"
    snapshot := file.read-contents snapshot-path
    image-path := fs.join tmp-dir "image.envelope"
    toit_ [
      "tool", "snapshot-to-image",
      "--format", "binary",
      "-m32",
      "-o", image-path,
      snapshot-path
    ]
    return file.read-contents image-path

  install-test image/ByteArray arg/string -> none:
    log "Sending test to device $name"
    socket_.out.little-endian.write-int32 arg.size
    socket_.out.write arg
    if already-installed:
      log "Sending already installed signal"
      socket_.out.little-endian.write-int32 -1
      log "set"
      installed-container.set true
      log "return"
      return

    socket_.out.little-endian.write-int32 image.size

    summer := crc.Crc32
    summer.add image
    socket_.out.write summer.get
    socket_.out.write image

    log "Waiting for test to be fully installed"
    installed-container.get

  run-test -> none:
    log "Running test on device $name"
    socket_.out.write RUN-TEST

setup-tester invocation/cli.Invocation:
  if os.env.get "TOIT_SKIP_SETUP": return

  ui := invocation.cli.ui
  toit-exe := invocation["toit-exe"]
  port-path := invocation["port"]
  envelope-path := invocation["envelope"]

  with-tmp-dir: | dir/string |
    tester-envelope-path := fs.join dir "tester.envelope"
    my-path := system.program-path
    my-dir := fs.dirname my-path
    mini-jag-source := fs.join my-dir "mini-jag.toit"
    mini-jag-snapshot-path := "$dir/mini-jag.snap"
    run-toit --ui=ui toit-exe [
      "compile",
      "--snapshot",
      "-o", mini-jag-snapshot-path,
      mini-jag-source
    ]
    run-toit --ui=ui toit-exe [
      "tool", "firmware",
      "container", "add", "mini-jag", mini-jag-snapshot-path,
      "-e", envelope-path,
      "-o", tester-envelope-path,
    ]
    wifi-config-path := fs.join dir "wifi-config.json"
    file.write-contents --path=wifi-config-path """
      {
        "wifi": {
          "wifi.ssid": "$invocation["wifi-ssid"]",
          "wifi.password": "$invocation["wifi-password"]"
        }
      }
    """
    run-toit --ui=ui toit-exe [
      "tool", "firmware", "flash",
      "-e", tester-envelope-path,
      "--config", wifi-config-path,
      "--port", port-path,
    ]

// ----------------------------------------------------------------------------
// EC618 host driver.
//
// The EC618 has no Wi-Fi and no host reset line in our rig, so the host talks
// the whole control protocol over the device's print UART. The device runs a
// resident agent (see mini-jag.toit / shared.toit) that never reboots itself
// between tests, so there is no reset to drive: we just open the serial port,
// handshake, install a container, run it, and stream its output back.

// Drives the resident mini-jag agent over a single UART. Protocol bytes are
// interleaved with the device's `[mini-jag] ...` / `[toit] ...` status lines;
// $read-ack skips and logs those so callers only ever see real ack bytes.
class Ec618Link:
  port_/uart.HostPort
  reader_/io.Reader
  writer_/io.Writer
  name_/string
  pending_/string := ""  // Partial line held until its newline arrives.

  constructor --port-path/string --baud-rate/int=115200 --name/string="ec618":
    port_ = uart.HostPort port-path --baud-rate=baud-rate
    reader_ = port_.in
    writer_ = port_.out
    name_ = name

  close -> none:
    flush-pending_
    port_.close

  send command/int -> none:
    writer_.write #[command]

  // Reads the next protocol byte, logging and skipping any interleaved
  // '['-led status line and stray CR/LF. Throws on timeout.
  read-ack --timeout-ms/int=5000 -> int:
    while true:
      head := with-timeout --ms=timeout-ms: reader_.peek-byte
      if head == '\r' or head == '\n':
        reader_.read-byte
        continue
      if head == '[':
        line := with-timeout --ms=timeout-ms: reader_.read-line
        if line: log "$name_: $line"
        continue
      reader_.read-byte
      return head

  expect what/string want/int --timeout-ms/int=5000 -> none:
    got := read-ack --timeout-ms=timeout-ms
    if got != want:
      throw "$what: expected '$(printable_ want)', got '$(printable_ got)'"

  // Pings until the resident agent answers, tolerating boot noise, then drains
  // the backlog of pong replies the agent buffered while booting.
  handshake --attempts/int=30 -> none:
    sleep --ms=1000  // Let any boot banner pass.
    succeeded := false
    attempts.repeat: | attempt/int |
      if not succeeded:
        send CMD-PING
        catch:
          if (read-ack --timeout-ms=1500) == ACK-PONG:
            log "$name_: agent responded (ping $(attempt + 1))"
            succeeded = true
    if not succeeded: throw "no response from the mini-jag agent on $name_"
    drain

  // Discards buffered input until the wire is quiet for $quiet-ms.
  drain --quiet-ms/int=400 -> none:
    while true:
      data/ByteArray? := null
      catch: data = with-timeout --ms=quiet-ms: reader_.read
      if not data: return

  // Reads and logs the raw console for $ms. Used to debug a trial boot that
  // never reconnects (a fault/reset loop in the staged slot shows up as a
  // hardfault dump or a repeating boot banner here, where the ack-oriented
  // $handshake would silently consume it).
  dump-raw --ms/int -> none:
    deadline := Time.monotonic-us + ms * 1000
    while Time.monotonic-us < deadline:
      data/ByteArray? := null
      catch: data = with-timeout --ms=1000: reader_.read
      if data: emit-device-output (data.to-string-non-throwing)
    flush-pending_

  // Sends the test argument (`<len:4 LE><bytes>`).
  send-arg arg/string -> none:
    bytes := arg.to-byte-array
    header := ByteArray 4
    io.LITTLE-ENDIAN.put-uint32 header 0 bytes.size
    send CMD-ARG
    writer_.write header
    writer_.write bytes
    expect "ARG" ACK-OK

  // Installs a container image, chunked with per-chunk acks so the small
  // device RX buffer never overflows on the flow-control-less UART.
  install-container image/ByteArray --chunk/int=2048 -> none:
    summer := crc.Crc32
    summer.add image
    header := ByteArray 8
    io.LITTLE-ENDIAN.put-uint32 header 0 image.size
    header.replace 4 summer.get
    send CMD-INSTALL
    writer_.write header
    expect "INSTALL ready" ACK-READY --timeout-ms=10_000
    offset := 0
    while offset < image.size:
      n := min chunk (image.size - offset)
      send-length-prefixed_ image offset n
      expect "INSTALL chunk@$offset" ACK-OK --timeout-ms=15_000
      offset += n
    expect "INSTALL commit" ACK-OK --timeout-ms=15_000

  // Streams the running test's output to the log until the agent reports the
  // test's exit code. Returns whether it exited cleanly (code 0).
  run --timeout-ms/int -> bool:
    send CMD-RUN
    deadline := Time.monotonic-us + timeout-ms * 1000
    marker := "$MINI-JAG-TAG run: test exited code="
    collected := ""
    next-ping-us := Time.monotonic-us  // Feed the device watchdog right away.
    while Time.monotonic-us < deadline:
      // The test runs in the BACKGROUND on the device, so its command loop keeps
      // reading the UART. Keep its general watchdog fed with a fire-and-forget
      // ping every few seconds (the agent feeds on it and stays silent while a
      // test runs, so it doesn't pollute the test output stream).
      if Time.monotonic-us >= next-ping-us:
        send CMD-PING
        next-ping-us = Time.monotonic-us + 3_000_000
      data/ByteArray? := null
      catch: data = with-timeout --ms=1000: reader_.read
      if not data: continue
      collected += emit-device-output (data.to-string-non-throwing)
      index := collected.index-of marker
      if index >= 0:
        rest := collected[index + marker.size ..]
        newline := rest.index-of "\n"
        if newline >= 0:
          code := -1
          catch: code = int.parse rest[..newline].trim
          return code == 0
      // The device reboots straight into the agent if the watchdog fires, so a
      // fresh ready banner mid-run means the test hung or crashed the device and
      // the watchdog recovered it — a failure, but the device is back on its own.
      if collected.contains MINI-JAG-EC618-READY:
        log "$name_: the watchdog reset the device during the test (recovered, no external reset)"
        return false
    log "$name_: timed out waiting for the test to finish"
    return false

  // --- firmware OTA (canonical FirmwareWriter path) -------------------------

  fw-begin size/int -> none:
    header := ByteArray 4
    io.LITTLE-ENDIAN.put-uint32 header 0 size
    send CMD-FW-BEGIN
    writer_.write header
    expect "FW-BEGIN" ACK-OK --timeout-ms=10_000

  fw-write-all image/ByteArray --chunk/int=4096 -> none:
    offset := 0
    start := Time.monotonic-us
    while offset < image.size:
      n := min chunk (image.size - offset)
      header := ByteArray 4
      io.BIG-ENDIAN.put-uint32 header 0 n
      send CMD-FW-WRITE
      writer_.write header
      expect "FW-WRITE ready@$offset" ACK-READY --timeout-ms=10_000
      send-bytes_ image offset n
      expect "FW-WRITE ok@$offset" ACK-OK --timeout-ms=30_000
      offset += n
      if offset % (32 * 1024) == 0 or offset == image.size:
        elapsed := (Time.monotonic-us - start) / 1_000_000.0
        rate := elapsed > 0 ? (offset / 1024.0 / elapsed) : 0.0
        log "$name_: wrote $offset/$image.size bytes ($(%.1f rate) KB/s)"

  fw-commit checksum/ByteArray -> none:
    send CMD-FW-COMMIT
    writer_.write checksum  // 32-byte SHA-256.
    expect "FW-COMMIT" ACK-OK --timeout-ms=30_000

  fw-upgrade -> none:
    send CMD-FW-UPGRADE
    expect "FW-UPGRADE" ACK-OK --timeout-ms=10_000
    // The device reboots into the trial slot now.

  trial -> bool:
    send CMD-TRIAL
    got := read-ack --timeout-ms=5000
    if got == ACK-TRIAL-YES: return true
    if got == ACK-TRIAL-NO: return false
    throw "TRIAL: unexpected '$(printable_ got)'"

  validate -> none:
    send CMD-VALIDATE
    expect "VALIDATE" ACK-OK --timeout-ms=10_000

  // --- internals ------------------------------------------------------------

  send-length-prefixed_ data/ByteArray offset/int length/int -> none:
    header := ByteArray 4
    io.BIG-ENDIAN.put-uint32 header 0 length
    writer_.write header
    send-bytes_ data offset length

  send-bytes_ data/ByteArray offset/int length/int -> none:
    writer_.write data[offset .. offset + length]

  // Appends $text to the partial-line buffer and logs every complete line.
  // Returns $text unchanged so callers can also scan for markers.
  emit-device-output text/string -> string:
    pending_ += text
    while true:
      newline := pending_.index-of "\n"
      if newline < 0: break
      line := pending_[..newline]
      if line.ends-with "\r": line = line[..line.size - 1]
      if line != "": log "$name_: $line"
      pending_ = pending_[newline + 1 ..]
    return text

  flush-pending_ -> none:
    if pending_ != "":
      log "$name_: $pending_"
      pending_ = ""

  printable_ value/int -> string:
    if ' ' <= value <= '~': return string.from-rune value
    return "0x$(%02x value)"

// Compiles a test to a 32-bit container image (the EC618 is 32-bit).
compile-test-image toit-exe/string test-path/string --tmp-dir/string --ui/cli.Ui -> ByteArray:
  snapshot-path := fs.join tmp-dir "test.snap"
  run-toit --ui=ui toit-exe ["compile", "--snapshot", "-o", snapshot-path, test-path]
  image-path := fs.join tmp-dir "test.image"
  run-toit --ui=ui toit-exe [
    "tool", "snapshot-to-image",
    "--format", "binary",
    "-m32",
    "-o", image-path,
    snapshot-path,
  ]
  return file.read-contents image-path

run-test-ec618 invocation/cli.Invocation:
  ui := invocation.cli.ui
  toit-exe := invocation["toit-exe"]
  port-path := invocation["port-board1"]
  test-path := invocation["test"]
  arg := invocation["arg"]
  if invocation["port-board2"] or invocation["test2"]:
    throw "ec618: dual-board tests are not supported"

  with-tmp-dir: | dir/string |
    log "Compiling $test-path"
    image := compile-test-image toit-exe test-path --tmp-dir=dir --ui=ui
    link := Ec618Link --port-path=port-path
    try:
      log "Connecting to the mini-jag agent on $port-path"
      link.handshake
      log "Installing test container ($image.size bytes)"
      link.send-arg arg
      link.install-container image
      log "Running test"
      // Outlast the device-side watchdog budget (~3 min) so a hung test is seen
      // through to the watchdog reset rather than timing out here first; the run
      // returns early either way (on the test's exit code or the reboot banner).
      passed := link.run --timeout-ms=240_000
      if not passed: throw "test did not pass"
      log "Test passed"
    finally:
      link.close

firmware-update invocation/cli.Invocation:
  ui := invocation.cli.ui
  toit-exe := invocation["toit-exe"]
  port-path := invocation["port"]
  envelope-path := invocation["envelope"]
  do-validate := invocation["validate"]

  with-tmp-dir: | dir/string |
    log "Building the canonical OTA image from $envelope-path (with mini-jag)"
    image := build-canonical-firmware toit-exe envelope-path --tmp-dir=dir --ui=ui
    checksum := sha256 image
    log "OTA image: $image.size bytes"

    link := Ec618Link --port-path=port-path
    try:
      log "Connecting to the mini-jag agent on $port-path"
      link.handshake
      log "Streaming firmware to the inactive slot"
      link.fw-begin image.size
      link.fw-write-all image
      link.fw-commit checksum
      log "Committed; rebooting into the trial slot"
      link.fw-upgrade

      if invocation["debug-boot"]:
        log "Capturing the raw trial-boot console for 15s"
        link.dump-raw --ms=15000

      log "Reconnecting after the reboot"
      sleep --ms=2000
      link.handshake
      if not link.trial: throw "device did not boot the trial slot"
      log "Booted the trial slot"
      if do-validate:
        link.validate
        log "Validated — the new firmware is now permanent"
      else:
        log "Left unvalidated — the next reset rolls back to the previous slot"
    finally:
      link.close

// Builds the EC618 canonical OTA image: embed the mini-jag agent in the target
// envelope (so we can drive + validate it after the OTA), then extract the
// canonical `[ size ][ table ][ body + extension ]` image the device's
// FirmwareWriter consumes (relocate-on-write).
build-canonical-firmware toit-exe/string envelope-path/string --tmp-dir/string --ui/cli.Ui -> ByteArray:
  my-dir := fs.dirname system.program-path
  mini-jag-source := fs.join my-dir "mini-jag.toit"
  mini-jag-snapshot := fs.join tmp-dir "mini-jag.snap"
  run-toit --ui=ui toit-exe ["compile", "--snapshot", "-o", mini-jag-snapshot, mini-jag-source]
  staged-envelope := fs.join tmp-dir "ota.envelope"
  run-toit --ui=ui toit-exe [
    "tool", "firmware", "container", "add", "mini-jag", mini-jag-snapshot,
    "-e", envelope-path,
    "-o", staged-envelope,
  ]
  canonical-path := fs.join tmp-dir "canonical.bin"
  run-toit --ui=ui toit-exe [
    "tool", "firmware", "extract",
    "-e", staged-envelope,
    "--format", "binary",
    "-o", canonical-path,
  ]
  return file.read-contents canonical-path

setup-tester-ec618 invocation/cli.Invocation:
  if os.env.get "TOIT_SKIP_SETUP": return

  ui := invocation.cli.ui
  toit-exe := invocation["toit-exe"]
  port-path := invocation["port"]
  envelope-path := invocation["envelope"]

  with-tmp-dir: | dir/string |
    my-dir := fs.dirname system.program-path
    mini-jag-source := fs.join my-dir "mini-jag.toit"
    mini-jag-snapshot := fs.join dir "mini-jag.snap"
    run-toit --ui=ui toit-exe ["compile", "--snapshot", "-o", mini-jag-snapshot, mini-jag-source]
    tester-envelope := fs.join dir "tester.envelope"
    run-toit --ui=ui toit-exe [
      "tool", "firmware", "container", "add", "mini-jag", mini-jag-snapshot,
      "-e", envelope-path,
      "-o", tester-envelope,
    ]
    // The EC618 flashes over the boot ROM (ectool); the operator must trigger
    // the boot ROM (power-cycle into download mode) while this runs.
    log "Flashing EC618 over the boot ROM — trigger boot/download mode now."
    run-toit --ui=ui toit-exe [
      "tool", "firmware", "flash",
      "-e", tester-envelope,
      "--port", port-path,
    ]

