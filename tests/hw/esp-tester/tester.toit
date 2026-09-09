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

SERIAL-CONTROL-TIMEOUT ::= "SERIAL_CONTROL_TIMEOUT"
TEST-COMPLETION-TIMEOUT ::= "TEST_COMPLETION_TIMEOUT"
RIG-PREFLIGHT-FAILED ::= "RIG_PREFLIGHT_FAILED"

DEVICE-READY-TIMEOUT-MS ::= 15_000
RIG-PREFLIGHT-TIMEOUT-MS ::= 5_000
CONTAINER-HEADER-TIMEOUT-MS ::= 10_000
CONTAINER-CHUNK-TIMEOUT-MS ::= 10_000
CONTAINER-INSTALL-TIMEOUT-MS ::= 30_000
CONTAINER-START-TIMEOUT-MS ::= 15_000
TEST-TIMEOUT-MS ::= 100_000
FLAKY-TEST-TIMEOUT-MS ::= 130_000

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
        cli.OptionEnum "control" ["serial", "network"]
            --help="The ESP32 control transport"
            --default="serial",
      ]
      --run=:: | invocation/cli.Invocation |
        if invocation["chip"] == CHIP-EC618:
          setup-tester-ec618 invocation
        else:
          if not invocation["wifi-ssid"] or not invocation["wifi-password"]:
            throw "ESP32 setup requires --wifi-ssid and --wifi-password"
          setup-tester invocation

  root-cmd.add setup-cmd

  preflight-cmd := cli.Command "preflight"
      --help="Verify the rig's serial paths and chip identities"
      --options=[
        cli.Option "port-board1"
            --help="The path to the UART port of board 1"
            --type="path"
            --required,
        cli.Option "port-board2"
            --help="The path to the UART port of board 2"
            --type="path"
            --required,
        cli.OptionEnum "chip" ["esp32", "esp32s3"]
            --help="The expected chip family"
            --required,
      ]
      --run=:: | invocation/cli.Invocation |
        preflight-rig invocation

  root-cmd.add preflight-cmd

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
        cli.OptionInt "fast-baud"
            --help="Hop the EC618 control UART to this baud after the handshake (115200 disables)"
            --default=921600,
        cli.OptionEnum "control" ["serial", "network"]
            --help="The ESP32 control transport"
            --default="serial",
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

  run-embedded-cmd := cli.Command "run-embedded"
      --help="Run a test container already embedded in the EC618 firmware slot"
      --options=[
        cli.Option "port"
            --help="The path to the EC618 control UART"
            --type="path"
            --required,
        cli.Option "arg"
            --help="The argument to pass to the test"
            --type="string"
            --default="",
        cli.OptionInt "fast-baud"
            --help="Hop the EC618 control UART to this baud after the handshake (115200 disables)"
            --default=921600,
      ]
      --run=:: | invocation/cli.Invocation |
        run-embedded-ec618 invocation
  root-cmd.add run-embedded-cmd

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
        cli.OptionInt "fast-baud"
            --help="Hop the control UART to this baud after each handshake (115200 disables)"
            --default=921600,
        cli.OptionInt "console-uart"
            --help="After commit, attach this console UART (0/1/2 or 255) to the NEW trial before rebooting.",
      ]
      --run=:: | invocation/cli.Invocation |
        firmware-update invocation
  root-cmd.add firmware-update-cmd

  root-cmd.run args

preflight-rig invocation/cli.Invocation:
  chip/string := invocation["chip"]
  expected-marker := chip == "esp32"
      ? "ets Jun  8 2016"
      : "ESP-ROM:esp32s3"
  Task.group [
    :: preflight-port "board1" invocation["port-board1"] chip expected-marker,
    :: preflight-port "board2" invocation["port-board2"] chip expected-marker,
  ]

preflight-port name/string path/string chip/string expected-marker/string:
  output := ""
  error := catch:
    port := uart.HostPort path --baud-rate=CONSOLE-BAUD-RATE
    try:
      port.set-control-flag uart.HostPort.CONTROL-FLAG-DTR false
      port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS true
      sleep --ms=500
      port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS false
      with-timeout --ms=RIG-PREFLIGHT-TIMEOUT-MS:
        while not output.contains expected-marker:
          data := port.in.read
          if not data: throw "Serial port closed"
          output += data.to-string-non-throwing
    finally:
      port.close
  if error:
    if output.size > 300: output = output[output.size - 300..]
    print "Rig preflight failed for $name: expected $chip on $path; error: $error; last serial output: $(output.trim)"
    throw RIG-PREFLIGHT-FAILED
  print "Rig preflight $name: identified $chip on $path"

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
  use-network := invocation["control"] == "network"
  test-timeout-ms := flaky ? FLAKY-TEST-TIMEOUT-MS : TEST-TIMEOUT-MS

  already-installed := false
  attempts := flaky ? 3 : 1
  attempts.repeat: | attempt/int |
    transfer-attempt := 0
    while true:
      print "\n"
      log "Attempt $(attempt + 1) of $attempts"
      error := catch:
        board1 := TestDevice
            --name="board1"
            --port-path=port-board1
            --ui=ui
            --toit-exe=toit-exe
            --already-installed=already-installed
            --use-network=use-network
        board2/TestDevice? := null

        try:
          board1-ready := monitor.Latch

          task::
            error := catch:
              image/ByteArray? := null
              Task.group [
                :: board1.connect,
                :: image = board1.compile-test test-path,
              ]
              board1.install-test image arg
              log "Board1 ready"
              board1-ready.set true
            if error: board1-ready.set --exception error

          if port-board2:
            board2 = TestDevice
                --name="board2"
                --port-path=port-board2
                --ui=ui
                --toit-exe=toit-exe
                --already-installed=already-installed
                --use-network=use-network
            image2/ByteArray? := null
            Task.group [
              :: board2.connect,
              :: image2 = board2.compile-test test2-path,
            ]
            board2.install-test image2 arg
            log "Board2 ready"

          board1-ready.get
          already-installed = true

          board1.run-test
          board1.wait-until-running
          if port-board2:
            board2.run-test
            board2.wait-until-running

          ui.emit --verbose "Waiting for all tests to be done."
          board1.wait-until-done test-timeout-ms
          log "Board1 done"
          if board2:
            board2.wait-until-done test-timeout-ms
            log "Board2 done"

          // Success. No need to run another attempt.
          return
        finally:
          board1.close
          if board2: board2.close

      if (error == UART-TRANSFER-ERROR or error == SERIAL-CONTROL-TIMEOUT) and transfer-attempt == 0:
        transfer-attempt++
        log "Retrying after a serial control failure"
        continue
      // If we didn't manage to install the test something went wrong.
      if not already-installed or attempt == attempts - 1: throw error
      break

class LoggingReader extends io.Reader:
  wrapped_/io.Reader
  on-data_/Lambda

  constructor .wrapped_ .on-data_:

  read_ -> ByteArray?:
    data := wrapped_.read
    if data: on-data_.call data
    return data

class TestDevice:
  static SNAPSHOT-NAME ::= "test.snap"
  name/string
  port/uart.HostPort? := ?
  toit-exe/string
  // Whether the test has already been installed on the device.
  already-installed/bool
  // Whether the control channel rides on TCP over WiFi instead of the
  // serial connection. The protocol is identical; only the transport
  // bring-up differs.
  use-network/bool
  read-task/Task? := null
  is-active/bool := false
  collected-output/string := ""
  // Consecutive UART chunks may belong to the same output line. Avoid adding
  // another timestamp when continuing such a line. This assumes that nothing
  // else writes to stdout between chunks of a partial UART line.
  output-at-new-line_/bool := true
  // One offset per $CHUNK-REQUEST the device has printed. The install paces its
  // writes on these, so the device is never sent data it hasn't asked for.
  chunk-requests_/monitor.Channel := monitor.Channel 2
  device-ready-latch/monitor.Latch := monitor.Latch
  installed-container/monitor.Latch := monitor.Latch
  running-container/monitor.Latch := monitor.Latch
  all-tests-done/monitor.Latch := monitor.Latch
  image-bytes-sent_/int := 0
  ui/cli.Ui
  tmp-dir/string

  network_/net.Client? := null
  socket_/tcp.Socket? := null

  constructor --.name --.toit-exe --port-path/string --.ui --.already-installed --.use-network:
    port = uart.HostPort port-path --baud-rate=CONSOLE-BAUD-RATE
    tmp-dir = directory.mkdtemp "/tmp/esp-tester"
    read-task = task --background:: read-output_

  read-output_:
    try:
      reader := LoggingReader port.in (:: | data/ByteArray | record-output_ data)
      while line/string? := read-output-line_ reader:
        if not is-active: continue
        dispatch-output-line_ reader line.trim
    finally:
      if port:
        port.close
        port = null
      // Publish termination only after the port has been released.  A UART
      // transfer retry may otherwise race with this cleanup when reopening
      // the same host serial device.
      read-task = null

  record-output_ data/ByteArray:
    if not is-active: return
    data-str := data.to-string-non-throwing
    if output-at-new-line_: data-str = "\n$data-str"
    if data-str.ends-with "\n":
      output-at-new-line_ = true
      data-str = data-str[.. data-str.size - 1]
    else:
      output-at-new-line_ = false

    write-output_ data-str
    collected-output += data-str

  write-output_ data/string:
    timestamp := Duration --us=(Time.monotonic-us - start-time-us)
    stdout-text := data.replace --all "\n" "\n$(%06d timestamp.in-ms)-$name: "
    pipe.stdout.out.write stdout-text

  read-output-line_ reader/io.Reader -> string?:
    // $io.Reader.read-line decodes strict UTF-8, but bytes corrupted around a
    // baud-rate transition must be treated as garbage rather than terminating
    // the output reader. Split on the byte delimiter and decode non-throwing.
    newline-index := reader.index-of '\n'
    if newline-index < 0:
      remaining := reader.buffered-size
      if remaining == 0: return null
      return (reader.read-bytes remaining).to-string-non-throwing
    data := reader.read-bytes newline-index
    reader.skip 1
    return data.to-string-non-throwing

  dispatch-output-line_ reader/io.Reader line/string:
    if line.contains MINI-JAG-LISTENING:
      set-latch_ device-ready-latch
      return
    if line.starts-with ALL-TESTS-DONE:
      set-latch_ all-tests-done
      return
    if line.starts-with UART-TRANSFER-ERROR:
      if not installed-container.has-value:
        installed-container.set --exception UART-TRANSFER-ERROR
      return
    if line.starts-with INSTALLED-CONTAINER:
      set-latch_ installed-container
      return
    if line.starts-with RUNNING-CONTAINER:
      set-latch_ running-container
      return
    if line.starts-with UART-INPUT-REQUEST:
      payload := line[UART-INPUT-REQUEST.size..].trim
      port.out.write "$payload\n" --flush
      return
    if line.starts-with UART-BAUD-RATE-REQUEST:
      payload := line[UART-BAUD-RATE-REQUEST.size..].trim
      handle-baud-rate-request_ reader payload
      return
    if line.starts-with CHUNK-REQUEST:
      handle-chunk-request_ line[CHUNK-REQUEST.size..].trim
      return
    decode-index := line.index-of JAG-DECODE
    if decode-index >= 0:
      handle-decode-request_ line[decode-index + JAG-DECODE.size..].trim

  handle-baud-rate-request_ reader/io.Reader payload/string:
    // Acknowledge at the current rate before both sides switch to the
    // requested rate.
    rate := int.parse payload
    port.out.write "$UART-BAUD-RATE-ACK\n" --flush
    // Some USB-UART adapters report an empty host queue before their hardware
    // has emitted the final bytes at the old rate.
    sleep --ms=UART-HOST-BAUD-RATE-SWITCH-DELAY-MS
    port.baud-rate = rate
    // The testee switches later than the host. Send the synchronization marker
    // only once both sides are expected to be listening at the new rate.
    sleep --ms=UART-BAUD-RATE-SYNC-DELAY-MS
    synced := false
    attempts := 0
    while not synced and attempts < UART-BAUD-RATE-SYNC-ATTEMPTS:
      attempts++
      port.out.write "$UART-BAUD-RATE-SYNC\n" --flush
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout --ms=UART-BAUD-RATE-SYNC-TIMEOUT-MS:
          while response/string? := read-output-line_ reader:
            if response.trim == UART-BAUD-RATE-SYNCED:
              synced = true
              break
            dispatch-output-line_ reader response.trim
    if not synced:
      log "$name timed out synchronizing baud rate $rate"
      throw SERIAL-CONTROL-TIMEOUT

  handle-chunk-request_ payload/string:
    // Publish the expected offset from the complete chunk request.
    offset := int.parse payload
    if not chunk-requests_.try-send offset:
      installed-container.set --exception UART-TRANSFER-ERROR

  handle-decode-request_ payload/string:
    if not file.is-file "$tmp-dir/$SNAPSHOT-NAME":
      // Without a snapshot this is probably an error during setup.
      all-tests-done.set --exception "Error detected"
      return
    snapshot-path := "$tmp-dir/$SNAPSHOT-NAME"
    toit_ ["decode", "-s", snapshot-path, payload]
    all-tests-done.set --exception "Error detected"

  set-latch_ latch/monitor.Latch:
    if latch.has-value: return
    latch.set true

  wait-for-control_ phase/string timeout-ms/int [block]:
    error := catch:
      with-timeout --ms=timeout-ms: block.call
    if error == DEADLINE-EXCEEDED-ERROR:
      lines := collected-output.split "\n"
      last-line := lines.last.trim
      message := "$name timed out during $phase after $(timeout-ms)ms; sent=$image-bytes-sent_ bytes; last output='$last-line'"
      log message
      throw SERIAL-CONTROL-TIMEOUT
    if error: throw error

  wait-for-test_ phase/string timeout-ms/int [block]:
    error := catch:
      with-timeout --ms=timeout-ms: block.call
    if error == DEADLINE-EXCEEDED-ERROR:
      lines := collected-output.split "\n"
      last-line := lines.last.trim
      message := "$name timed out during $phase after $(timeout-ms)ms; last output='$last-line'"
      log message
      throw TEST-COMPLETION-TIMEOUT
    if error: throw error

  close:
    if read-task:
      read-task.cancel
      // Task.cancel is asynchronous.  Wait for the reader's finally block to
      // close the serial device before a retry constructs another TestDevice.
      critical-do --no-respect-deadline:
        with-timeout --ms=1_000:
          while read-task: sleep --ms=1
    if file.is-directory tmp-dir:
      directory.rmdir --recursive tmp-dir
    disconnect-network

  toit_ args/List:
    run-toit toit-exe args --ui=ui

  connect:
    log "Connecting to $name"
    // Reset the device.
    ui.emit --verbose "Resetting $name."
    port.set-control-flag uart.HostPort.CONTROL-FLAG-DTR false
    port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS true
    is-active = true
    sleep --ms=500
    port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS false

    ui.emit --verbose "Waiting for $name to be ready."
    wait-for-control_ "device readiness" DEVICE-READY-TIMEOUT-MS: device-ready-latch.get
    ui.emit --verbose "Device $name is ready."

    if not use-network: return

    lines/List := collected-output.split "\n"
    lines.map --in-place: it.trim
    listening-line-index := lines.index-of --last MINI-JAG-LISTENING
    host-port-line := lines[listening-line-index - 1]
    parts := host-port-line.split ":"
    network_ = net.open
    socket_ = network_.tcp-connect parts[0] (int.parse parts[1])
    ui.emit --info "Connected to $host-port-line."

  // The writer of the control channel: the TCP socket for network control,
  // the serial port itself for serial control.
  control-out -> io.Writer:
    if use-network: return socket_.out
    return port.out

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
    out := control-out
    wait-for-control_ "container header" CONTAINER-HEADER-TIMEOUT-MS:
      out.little-endian.write-int32 arg.size
      out.write arg
    if already-installed:
      log "Sending already installed signal"
      wait-for-control_ "installed-container signal" CONTAINER-HEADER-TIMEOUT-MS:
        out.little-endian.write-int32 -1
        out.flush
      log "set"
      installed-container.set true
      log "return"
      return

    summer := crc.Crc32
    summer.add image
    wait-for-control_ "container header" CONTAINER-HEADER-TIMEOUT-MS:
      out.little-endian.write-int32 image.size
      out.write summer.get
      // Send the header before waiting for the device to request image data.
      // This is necessary for the serial transport, whose writer may buffer the
      // small header at high baud rates.
      out.flush
    // The device pulls the image chunk by chunk: it prints a request
    // whenever it is ready for more. Never send more than requested, since
    // the serial transport has no flow control.
    sent := 0
    while sent < image.size:
      chunk-end := min (sent + CHUNK-SIZE) image.size
      wait-for-control_ "container chunk at offset $sent" CONTAINER-CHUNK-TIMEOUT-MS:
        requested-offset/int := chunk-requests_.receive
        if requested-offset != sent:
          log "$name requested chunk $requested-offset while host expected $sent"
          throw UART-TRANSFER-ERROR
        out.little-endian.write-int32 sent
        out.little-endian.write-int32 chunk-end - sent
        out.write image[sent..chunk-end]
        out.flush
      sent = chunk-end
      image-bytes-sent_ = sent

    log "Waiting for test to be fully installed"
    wait-for-control_ "container installation" CONTAINER-INSTALL-TIMEOUT-MS:
      installed-container.get

  run-test -> none:
    log "Running test on device $name"
    if use-network:
      socket_.out.write RUN-TEST
    else:
      port.out.write RUN-TEST --flush
    // mini-jag receives the run signal at $CONTROL-BAUD-RATE, then resets
    // before starting the test. The next container starts its console at the
    // default rate, which lets console tests negotiate their own rate.
    sleep --ms=UART-HOST-BAUD-RATE-SWITCH-DELAY-MS
    port.baud-rate = CONSOLE-BAUD-RATE

  wait-until-running:
    wait-for-control_ "container start" CONTAINER-START-TIMEOUT-MS:
      running-container.get

  wait-until-done timeout-ms/int:
    wait-for-test_ "test completion" timeout-ms:
      all-tests-done.get

setup-tester invocation/cli.Invocation:
  if os.env.get "TOIT_SKIP_SETUP": return

  ui := invocation.cli.ui
  toit-exe := invocation["toit-exe"]
  port-path := invocation["port"]
  envelope-path := invocation["envelope"]
  control := invocation["control"]

  with-tmp-dir: | dir/string |
    tester-envelope-path := fs.join dir "tester.envelope"
    my-path := system.program-path
    my-dir := fs.dirname my-path
    mini-jag-source := fs.join my-dir "mini-jag.toit"
    mini-jag-snapshot-path := "$dir/mini-jag.snap"
    mini-jag-assets-path := "$dir/mini-jag.assets"
    control-path := "$dir/control"
    run-toit --ui=ui toit-exe [
      "compile",
      "--snapshot",
      "-o", mini-jag-snapshot-path,
      mini-jag-source
    ]
    file.write-contents --path=control-path control
    run-toit --ui=ui toit-exe [
      "tool", "assets",
      "create",
      "--assets", mini-jag-assets-path,
    ]
    run-toit --ui=ui toit-exe [
      "tool", "assets",
      "add",
      "--assets", mini-jag-assets-path,
      CONTROL-ASSET,
      control-path,
    ]
    run-toit --ui=ui toit-exe [
      "tool", "firmware",
      "container", "add", "mini-jag", mini-jag-snapshot-path,
      "--assets", mini-jag-assets-path,
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
  // The fast rate this link may hop to (see switch-baud); the handshake
  // also probes it, in case the device lingers there from a previous run.
  fast-baud_/int
  pending_/string := ""  // Partial line held until its newline arrives.

  constructor --port-path/string --baud-rate/int=115200 --fast-baud/int=921600 --name/string="ec618":
    port_ = uart.HostPort port-path --baud-rate=baud-rate
    reader_ = port_.in
    writer_ = port_.out
    fast-baud_ = fast-baud
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
      // Dump whatever the device says next — the mismatch byte is usually
      // the first character of an error/trace line that explains it.
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout --ms=1500:
          8.repeat:
            line := reader_.read-line
            if line: log "$name_ (post-mismatch): $line"
      throw "$what: expected '$(printable_ want)', got '$(printable_ got)'"

  // Pings until the resident agent answers, tolerating boot noise, then drains
  // the backlog of pong replies the agent buffered while booting.
  handshake --attempts/int=30 -> none:
    // A (re)booted device always talks 115200 (CMD-BAUD switches are lost
    // on reset) — but a device still alive from a PREVIOUS tester
    // invocation may be lingering at the fast rate (until its 60 s idle
    // watchdog resets it). Alternate the ping attempts across both rates.
    rates := fast-baud_ != 115200 ? [115200, fast-baud_] : [115200]
    initial-rate-error := catch: port_.baud-rate = 115200
    if initial-rate-error:
      log "$name_: could not initially select 115200 baud: $initial-rate-error"
    sleep --ms=1000  // Let the boot banner start.
    // Drain the post-reset boot backlog FIRST. After a reset the device streams a
    // long boot-ROM + bootloader banner (hundreds of mostly non-'['-led bytes);
    // read-ack treats each as a stray byte and consumes only ONE per ping attempt,
    // so without clearing the backlog the 30 attempts run out long before reaching
    // the agent's pong (this is why a plain reconnect failed while --debug-boot,
    // which dumps the raw console first, succeeded). Bounded so a boot-looping
    // device can't wedge us here; on a cold connect the line is already quiet so
    // this returns after one short read timeout.
    drain-deadline := Time.monotonic-us + 10_000_000
    while Time.monotonic-us < drain-deadline:
      data/ByteArray? := null
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        data = with-timeout --ms=600: reader_.read
      if not data: break  // ~600 ms quiet => backlog cleared, agent up and idle.
    succeeded := false
    attempts.repeat: | attempt/int |
      if not succeeded:
        // The host tty can transiently fail a rate change or a write
        // (EBUSY/EIO); skip to the next attempt rather than killing the
        // whole tool.
        rate-error := catch: port_.baud-rate = rates[attempt % rates.size]
        if rate-error:
          log "$name_: baud selection failed on ping $(attempt + 1): $rate-error"
        ping-error := catch:
          send CMD-PING
          ack := read-ack --timeout-ms=1500
          if ack == ACK-PONG:
            log "$name_: agent responded (ping $(attempt + 1), $port_.baud-rate baud)"
            succeeded = true
          else:
            // A ping sent at the wrong baud makes a live agent print a status
            // line at its own baud. After switching rates that line can appear
            // as a backlog of unrelated ack-sized bytes; consuming only one
            // byte per attempt exhausts all retries before we reach its pong.
            log "$name_: ping $(attempt + 1) got stray '$(printable_ ack)'"
            drain --quiet-ms=100
        if ping-error:
          log "$name_: ping $(attempt + 1) failed: $ping-error"
    if not succeeded: throw "no response from the mini-jag agent on $name_"
    drain

  // Changes the control UART to $baud (e.g. 921600 for bulk transfers).
  // Call after a successful handshake. Returns whether the device made
  // the switch; on failure the link stays at its current rate.
  switch-baud baud/int -> bool:
    old-baud := port_.baud-rate
    if baud == old-baud: return true
    header := ByteArray 4
    io.LITTLE-ENDIAN.put-uint32 header 0 baud
    send CMD-BAUD
    writer_.write header
    timeout-error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      if (read-ack --timeout-ms=2000) == ACK-OK:
        port_.baud-rate = baud
        log "$name_: control UART now at $baud baud"
        // The agent's "baud=" status line arrives at the new rate; a
        // mismatch would surface here as garbage instead of an ack later.
        drain --quiet-ms=300
        return true
    if timeout-error:
      log "$name_: timed out waiting for the baud-switch acknowledgement"
    log "$name_: baud switch to $baud failed; staying at $old-baud"
    return false

  // Discards buffered input until the wire is quiet for $quiet-ms.
  drain --quiet-ms/int=400 -> none:
    while true:
      data/ByteArray? := null
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        data = with-timeout --ms=quiet-ms: reader_.read
      if not data: return

  // Reads and logs the raw console for $ms. Used to debug a trial boot that
  // never reconnects (a fault/reset loop in the staged slot shows up as a
  // hardfault dump or a repeating boot banner here, where the ack-oriented
  // $handshake would silently consume it).
  dump-raw --ms/int -> none:
    deadline := Time.monotonic-us + ms * 1000
    while Time.monotonic-us < deadline:
      data/ByteArray? := null
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        data = with-timeout --ms=1000: reader_.read
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
  run --timeout-ms/int --embedded/bool=false -> bool:
    send (embedded ? CMD-RUN-EMBEDDED : CMD-RUN)
    deadline := Time.monotonic-us + timeout-ms * 1000
    marker := "$MINI-JAG-TAG run: test exited code="
    wait-failed-marker := "$MINI-JAG-TAG run: test wait failed"
    cleanup-failed-marker := "$MINI-JAG-TAG run: test cleanup failed"
    collected := ""
    expected-reboot-wake/string? := null
    next-ping-us := Time.monotonic-us  // Feed the device watchdog right away.
    while Time.monotonic-us < deadline:
      // The test runs in the BACKGROUND on the device, so its command loop keeps
      // reading the UART. Keep its general watchdog fed with a fire-and-forget
      // ping every few seconds (the agent feeds on it and stays silent while a
      // test runs, so it doesn't pollute the test output stream).
      if not expected-reboot-wake and Time.monotonic-us >= next-ping-us:
        send CMD-PING
        next-ping-us = Time.monotonic-us + 3_000_000
      data/ByteArray? := null
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        data = with-timeout --ms=1000: reader_.read
      if not data: continue
      collected += emit-device-output (data.to-string-non-throwing)

      if not expected-reboot-wake:
        expectation := collected.index-of EC618-EXPECT-REBOOT-WAKE-TAG
        if expectation >= 0:
          rest := collected[expectation + EC618-EXPECT-REBOOT-WAKE-TAG.size ..]
          newline := rest.index-of "\n"
          if newline >= 0:
            expected-reboot-wake = rest[..newline].trim
            if expected-reboot-wake != "pad" and expected-reboot-wake != "rtc":
              log "$name_: invalid expected reboot wake cause '$expected-reboot-wake'"
              return false
            // Deep sleep resets the device UART to 115200. Switch as soon as
            // the test's final marker has arrived, so the reboot banner is
            // decoded instead of becoming fast-baud garbage.
            if port_.baud-rate != 115200:
              rate-error := catch: port_.baud-rate = 115200
              if rate-error:
                log "$name_: could not select 115200 for the expected reboot: $rate-error"
                return false

      index := collected.index-of marker
      if index >= 0:
        rest := collected[index + marker.size ..]
        newline := rest.index-of "\n"
        if newline >= 0:
          code := -1
          parse-error := catch: code = int.parse rest[..newline].trim
          if parse-error:
            log "$name_: invalid test exit code from the agent: $parse-error"
            return false
          return code == 0
      // The agent survived but could not obtain the test's exit code (e.g. the
      // container-wait machinery threw). The test's verdict is unknown — fail.
      if collected.contains wait-failed-marker:
        log "$name_: the agent could not obtain the test's exit code"
        return false
      if collected.contains cleanup-failed-marker:
        log "$name_: the agent could not uninstall the completed test"
        return false
      // The device reboots straight into the agent if the watchdog fires, so a
      // fresh ready banner mid-run means the test hung or crashed the device and
      // the watchdog recovered it — a failure, but the device is back on its own.
      ready-index := collected.index-of MINI-JAG-EC618-READY
      if ready-index >= 0:
        // Serial reads may split the status line anywhere. Do not classify a
        // deliberate reboot from a prefix such as "... ready reset=pow":
        // the later part of that same line carries the decisive wake field.
        ready-rest := collected[ready-index ..]
        if ready-rest.contains "\n":
          if expected-reboot-wake:
            if ready-rest.contains " wake=$expected-reboot-wake ":
              log "$name_: deliberate reboot woke from $expected-reboot-wake as expected"
              return true
            log "$name_: deliberate reboot had the wrong wake cause (expected $expected-reboot-wake)"
            return false
          log "$name_: the watchdog reset the device during the test (recovered, no external reset)"
          return false
    // On a fast-baud link a rebooted device (back at 115200) prints its
    // ready banner as garbage, so the recovery check above can't see it.
    // Probe at 115200 before declaring a plain timeout.
    if port_.baud-rate != 115200:
      rate-error := catch: port_.baud-rate = 115200
      if rate-error:
        log "$name_: could not select 115200 baud for recovery: $rate-error"
      else:
        drain --quiet-ms=300
        send CMD-PING
        catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
          if (read-ack --timeout-ms=1500) == ACK-PONG:
            log "$name_: the watchdog reset the device during the test (recovered at 115200)"
            return false
    // Do not abandon the device process. Ask the resident agent to stop it:
    // Container.stop runs Toit finally blocks and native resource destructors,
    // so a timed-out peripheral operation releases its controller and pads.
    // The acknowledgement is written before the potentially blocking teardown.
    cancel-error := catch:
      send CMD-CANCEL
      expect "CANCEL" ACK-OK --timeout-ms=3000
    if cancel-error:
      log "$name_: timed out; could not request test cancellation: $cancel-error"
    else:
      log "$name_: timed out; requested in-device test cancellation"
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
  // The EC618 registry is 64 KiB. O2 keeps network test images below that
  // limit, while --enable-asserts preserves the hardware tests' checks.
  run-toit --ui=ui toit-exe [
    "compile",
    "--snapshot",
    "-O2",
    "--enable-asserts",
    "--project-root",
    fs.dirname test-path,
    "-o",
    snapshot-path,
    test-path,
  ]
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
    link := Ec618Link --port-path=port-path --fast-baud=invocation["fast-baud"]
    try:
      log "Connecting to the mini-jag agent on $port-path"
      link.handshake
      link.switch-baud invocation["fast-baud"]
      log "Installing test container ($image.size bytes)"
      link.send-arg arg
      link.install-container image
      log "Running test"
      // Outlast the device-side watchdog budget (~3 min) so a hung test is seen
      // through to the watchdog reset rather than timing out here first; the run
      // returns early either way (on the test's exit code or the reboot banner).
      passed := link.run --timeout-ms=240_000
      if not passed: throw "test did not pass"
      if not (link.switch-baud 115200):
        throw "test passed, but restoring the control UART to 115200 failed"
      log "Test passed"
    finally:
      link.close

run-embedded-ec618 invocation/cli.Invocation:
  port-path := invocation["port"]
  link := Ec618Link --port-path=port-path --fast-baud=invocation["fast-baud"]
  try:
    log "Connecting to the mini-jag agent on $port-path"
    link.handshake
    link.switch-baud invocation["fast-baud"]
    link.send-arg invocation["arg"]
    log "Running embedded test container"
    passed := link.run --timeout-ms=240_000 --embedded
    if not passed: throw "embedded test did not pass"
    if not (link.switch-baud 115200):
      throw "embedded test passed, but restoring the control UART to 115200 failed"
    log "Embedded test passed"
  finally:
    link.close

firmware-update invocation/cli.Invocation:
  ui := invocation.cli.ui
  toit-exe := invocation["toit-exe"]
  port-path := invocation["port"]
  envelope-path := invocation["envelope"]
  do-validate := invocation["validate"]
  pending-console/int? := invocation["console-uart"]

  with-tmp-dir: | dir/string |
    log "Building the canonical OTA image from $envelope-path (with mini-jag)"
    image := build-canonical-firmware toit-exe envelope-path --tmp-dir=dir --ui=ui
    checksum := sha256 image
    log "OTA image: $image.size bytes"

    fast-baud := invocation["fast-baud"]
    link := Ec618Link --port-path=port-path --fast-baud=fast-baud
    try:
      log "Connecting to the mini-jag agent on $port-path"
      link.handshake
      link.switch-baud fast-baud
      log "Streaming firmware to the inactive slot"
      link.fw-begin image.size
      link.fw-write-all image
      link.fw-commit checksum
      if pending-console != null:
        log "Attaching console UART $pending-console to the staged trial"
        console-source := fs.join dir "set-trial-console.toit"
        file.write-contents
            --path=console-source
            "import ec618\n\nmain args:\n  ec618.set-console-uart (int.parse args[0])\n"
        console-image := compile-test-image toit-exe console-source --tmp-dir=dir --ui=ui
        link.send-arg "$pending-console"
        link.install-container console-image
        if not (link.run --timeout-ms=30_000):
          throw "could not attach console UART $pending-console to the staged trial"
      log "Committed; rebooting into the trial slot"
      link.fw-upgrade

      if invocation["debug-boot"]:
        log "Capturing the raw trial-boot console for 15s"
        link.dump-raw --ms=15000

      log "Reconnecting after the reboot"
      sleep --ms=2000
      link.handshake
      link.switch-baud fast-baud
      if not link.trial: throw "device did not boot the trial slot"
      log "Booted the trial slot"

      // The agent answering is NOT enough to validate: a firmware whose
      // resident agent runs fine can still crash on container SPAWNS (seen
      // in the wild — every test reset the device while ping/install were
      // healthy, and the validated firmware had no working escape route).
      // Spawn a real container before committing to this firmware.
      log "Smoke test: spawning a container on the trial firmware"
      smoke-path := fs.join dir "fw-smoke.toit"
      file.write-contents --path=smoke-path """
        main:
          print "fw-smoke: container spawned"
        """
      smoke-image := compile-test-image toit-exe smoke-path --tmp-dir=dir --ui=ui
      link.send-arg ""
      link.install-container smoke-image
      if not (link.run --timeout-ms=60_000):
        throw "trial firmware failed the container smoke test — left unvalidated (next reset rolls back)"
      log "Smoke test passed"

      if do-validate:
        link.validate
        log "Validated — the new firmware is now permanent"
      else:
        log "Left unvalidated — the next reset rolls back to the previous slot"
      if not (link.switch-baud 115200):
        throw "firmware update passed, but restoring the control UART to 115200 failed"
    finally:
      link.close

// Adds one container ($name from $source.toit, next to this program) to the
// $in envelope, writing the result to $out.
add-container_ toit-exe/string name/string source/string --in/string --out/string --tmp-dir/string --ui/cli.Ui -> none:
  snapshot := fs.join tmp-dir "$(name).snap"
  run-toit --ui=ui toit-exe ["compile", "--snapshot", "-o", snapshot, source]
  run-toit --ui=ui toit-exe ["tool", "firmware", "container", "add", name, snapshot, "-e", in, "-o", out]

// Embeds the EC618 agent containers in $envelope, writing the result to $out:
// the mini-jag agent (so we can drive + validate it) plus the sleeper keep-alive
// container (so a crash of the agent can't deep-sleep/brick the board — see
// sleeper.toit).
add-ec618-containers toit-exe/string envelope/string out/string --tmp-dir/string --ui/cli.Ui -> none:
  my-dir := fs.dirname system.program-path
  with-mini-jag := fs.join tmp-dir "with-mini-jag.envelope"
  add-container_ toit-exe "mini-jag" (fs.join my-dir "mini-jag.toit") --in=envelope --out=with-mini-jag --tmp-dir=tmp-dir --ui=ui
  add-container_ toit-exe SLEEPER-NAME (fs.join my-dir "sleeper.toit") --in=with-mini-jag --out=out --tmp-dir=tmp-dir --ui=ui

// Builds the EC618 canonical OTA image: embed the agent containers in the target
// envelope (so we can drive + validate it after the OTA), then extract the
// canonical `[ size ][ table ][ body + extension ]` image the device's
// FirmwareWriter consumes (relocate-on-write).
build-canonical-firmware toit-exe/string envelope-path/string --tmp-dir/string --ui/cli.Ui -> ByteArray:
  staged-envelope := fs.join tmp-dir "ota.envelope"
  add-ec618-containers toit-exe envelope-path staged-envelope --tmp-dir=tmp-dir --ui=ui
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
    tester-envelope := fs.join dir "tester.envelope"
    add-ec618-containers toit-exe envelope-path tester-envelope --tmp-dir=dir --ui=ui
    // The EC618 flashes over the boot ROM (ectool); the operator must trigger
    // the boot ROM (power-cycle into download mode) while this runs.
    log "Flashing EC618 over the boot ROM — trigger boot/download mode now."
    run-toit --ui=ui toit-exe [
      "tool", "firmware", "flash",
      "-e", tester-envelope,
      "--port", port-path,
    ]
    // A full flash has no validate/rollback safety net (unlike OTA, where an
    // image that fails to come up never validates and the old slot returns).
    // So verify the result actually boots and serves instead of reporting
    // success on a dead board: poll the agent handshake while the device
    // comes up. The chip auto-reboots into the fresh firmware after the
    // burn — no PWRKEY needed (that is only for power-on after a
    // power-cycle). (Learned the hard way: a base image whose agent threw
    // during startup flashed "successfully" and the failure surfaced only
    // minutes later as silent watchdog resets.)
    log "Flash done — the device auto-reboots; waiting for the agent."
    // The burn itself does not use $port-path (ectool finds the boot-ROM
    // ACM on its own), so a wrong or not-yet-enumerated --port only
    // surfaces HERE — after a successful burn. Wait for the path instead
    // of crashing, and if it never shows, be explicit that the flash
    // itself went through.
    port-deadline := Time.monotonic-us + 30_000_000
    while (file.stat port-path) == null:
      if Time.monotonic-us > port-deadline:
        throw "flash succeeded, but cannot verify the image: port $port-path never appeared (wrong --port? adapter unplugged?)"
      sleep --ms=500
    link := Ec618Link --port-path=port-path
    try:
      link.handshake --attempts=90
      log "Agent is up — the flashed image is healthy."
    finally:
      link.close
