// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import crypto.crc
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

ALL-TESTS-DONE ::= "All tests done"
JAG-DECODE ::= "jag decode"

SERIAL-CONTROL-TIMEOUT ::= "SERIAL_CONTROL_TIMEOUT"
TEST-COMPLETION-TIMEOUT ::= "TEST_COMPLETION_TIMEOUT"

DEVICE-READY-TIMEOUT-MS ::= 15_000
CONTAINER-HEADER-TIMEOUT-MS ::= 10_000
CONTAINER-CHUNK-TIMEOUT-MS ::= 10_000
CONTAINER-INSTALL-TIMEOUT-MS ::= 30_000
CONTAINER-START-TIMEOUT-MS ::= 15_000
TEST-TIMEOUT-MS ::= 100_000
FLAKY-TEST-TIMEOUT-MS ::= 130_000

start-time-us/int := ?

log message/string:
  duration := Duration --us=(Time.monotonic-us - start-time-us)
  lines := message.split "\n"
  lines.do: print_ "--- $(%06d duration.in-ms): $it"

main args:
  start-time-us = Time.monotonic-us
  root-cmd := cli.Command "tester"
      --help="Run tests on an ESP tester"
      --options=[
        cli.Option "toit-exe"
            --help="The path to the Toit executable"
            --type="path"
            --required,
      ]

  setup-cmd := cli.Command "setup"
      --help="Setup the ESP tester on the device"
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
            --help="The path to the envelope"
            --type="path"
            --required,
        cli.Option "wifi-ssid"
            --help="The WiFi SSID"
            --type="string"
            --required,
        cli.Option "wifi-password"
            --help="The WiFi password"
            --type="string"
            --required,
        cli.OptionEnum "control" ["serial", "network"]
            --help="The transport for the control channel"
            --default="serial",
      ]
      --run=:: | invocation/cli.Invocation |
        setup-tester invocation

  root-cmd.add setup-cmd

  run-cmd := cli.Command "run"
      --help="Run a test on the ESP"
      --options=[
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
        cli.OptionEnum "control" ["serial", "network"]
            --help="The transport for the control channel"
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
        run-test invocation
  root-cmd.add run-cmd

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

class OutputLine:
  payload/string
  end-offset/int

  constructor .payload .end-offset:

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
  // Offset into $collected-output up to which UART input requests have
  // been answered.
  uart-input-handled_/int := 0
  // Offset into $collected-output up to which UART baud-rate requests have
  // been answered.
  uart-baud-rate-handled_/int := 0
  // One offset per $CHUNK-REQUEST the device has printed. The install paces its
  // writes on these, so the device is never sent data it hasn't asked for.
  chunk-requests_/monitor.Channel := monitor.Channel 2
  // Offset into $collected-output up to which chunk requests have been
  // counted.
  chunk-requests-handled_/int := 0
  ready-latch/monitor.Latch := monitor.Latch
  installed-container/monitor.Latch := monitor.Latch
  running-container/monitor.Latch := monitor.Latch
  all-tests-done/monitor.Latch := monitor.Latch
  image-bytes-sent_/int := 0
  baud-sync-task_/Task? := null
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
      reader := port.in
      at-new-line := true
      while data/ByteArray? := reader.read:
        if not is-active: continue
        at-new-line = handle-output-chunk_ data at-new-line
    finally:
      if port:
        port.close
        port = null
      // Publish termination only after the port has been released.  A UART
      // transfer retry may otherwise race with this cleanup when reopening
      // the same host serial device.
      read-task = null

  handle-output-chunk_ data/ByteArray at-new-line/bool -> bool:
    data-str := data.to-string-non-throwing
    if at-new-line: data-str = "\n$data-str"
    if data-str.ends-with "\n":
      at-new-line = true
      data-str = data-str[.. data-str.size - 1]
    else:
      at-new-line = false

    write-output_ data-str
    collected-output += data-str
    handle-state-markers_
    handle-uart-input-requests_ at-new-line
    handle-baud-rate-requests_ at-new-line
    handle-chunk-requests_ at-new-line
    handle-decode-request_ at-new-line
    return at-new-line

  write-output_ data/string:
    timestamp := Duration --us=(Time.monotonic-us - start-time-us)
    stdout-text := data.replace --all "\n" "\n$(%06d timestamp.in-ms)-$name: "
    pipe.stdout.out.write stdout-text

  handle-state-markers_:
    if collected-output.contains MINI-JAG-LISTENING:
      set-latch_ ready-latch
      stop-baud-sync_
    set-latch-if-seen_ ALL-TESTS-DONE all-tests-done
    if output-contains-line_ UART-TRANSFER-ERROR:
      if not installed-container.has-value:
        installed-container.set --exception UART-TRANSFER-ERROR
    set-latch-if-seen_ INSTALLED-CONTAINER installed-container
    set-latch-if-seen_ RUNNING-CONTAINER running-container

  set-latch-if-seen_ marker/string latch/monitor.Latch:
    if output-contains-line_ marker: set-latch_ latch

  output-contains-line_ marker/string -> bool:
    return collected-output.contains "\n$marker"

  handle-uart-input-requests_ at-new-line/bool:
    // When the device prints a marker line, write the payload back to it over
    // the serial connection.
    while line/OutputLine? := next-output-line_ "\n$UART-INPUT-REQUEST" uart-input-handled_ at-new-line:
      uart-input-handled_ = line.end-offset
      port.out.write "$(line.payload)\n" --flush

  handle-baud-rate-requests_ at-new-line/bool:
    // Acknowledge at the current rate before both sides switch to the
    // requested rate.
    while line/OutputLine? := next-output-line_ "\n$UART-BAUD-RATE-REQUEST" uart-baud-rate-handled_ at-new-line:
      rate := int.parse line.payload
      uart-baud-rate-handled_ = line.end-offset
      port.out.write "$UART-BAUD-RATE-ACK\n" --flush
      // Some USB-UART adapters report an empty host queue before their
      // hardware has emitted the final bytes at the old rate.
      sleep --ms=UART-HOST-BAUD-RATE-SWITCH-DELAY-MS
      port.baud-rate = rate
      start-baud-sync_

  start-baud-sync_:
    baud-sync-task_ = task --background::
      sleep --ms=UART-BAUD-RATE-SYNC-DELAY-MS
      while not ready-latch.has-value:
        port.out.write "$UART-BAUD-RATE-SYNC\n" --flush
        sleep --ms=UART-BAUD-RATE-SYNC-RETRY-MS

  stop-baud-sync_:
    if not baud-sync-task_: return
    baud-sync-task_.cancel
    baud-sync-task_ = null

  handle-chunk-requests_ at-new-line/bool:
    // Publish the expected offset from each complete chunk request.
    while line/OutputLine? := next-output-line_ "\n$CHUNK-REQUEST" chunk-requests-handled_ at-new-line:
      offset := int.parse line.payload
      chunk-requests-handled_ = line.end-offset
      if not chunk-requests_.try-send offset:
        installed-container.set --exception UART-TRANSFER-ERROR

  handle-decode-request_ at-new-line/bool:
    if not collected-output.contains JAG-DECODE: return
    if not file.is-file "$tmp-dir/$SNAPSHOT-NAME":
      // Without a snapshot this is probably an error during setup.
      all-tests-done.set --exception "Error detected"
      return
    line := next-output-line_ JAG-DECODE 0 at-new-line --require-newline
    if not line: return  // Wait for the rest of the line.
    snapshot-path := "$tmp-dir/$SNAPSHOT-NAME"
    toit_ ["decode", "-s", snapshot-path, line.payload]
    all-tests-done.set --exception "Error detected"

  next-output-line_ marker/string offset/int at-new-line/bool --require-newline/bool=false -> OutputLine?:
    marker-index := collected-output.index-of marker offset
    if marker-index < 0: return null
    payload-start := marker-index + marker.size
    line-end := collected-output.index-of "\n" payload-start
    if line-end < 0:
      // The trailing newline of a chunk is stripped and only added back with
      // the next chunk, so a completed chunk means a completed line.
      if require-newline or not at-new-line: return null
      line-end = collected-output.size
    payload := collected-output[payload-start..line-end].trim
    return OutputLine payload line-end

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
    stop-baud-sync_
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
    wait-for-control_ "device readiness" DEVICE-READY-TIMEOUT-MS: ready-latch.get
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
