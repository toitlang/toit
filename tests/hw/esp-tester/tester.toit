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
import monitor
import net
import net.tcp
import system
import uart
import .shared

ALL-TESTS-DONE ::= "All tests done"
JAG-DECODE ::= "jag decode"

start-time-us/int := ?

log message/string:
  duration := Duration --us=(Time.monotonic-us - start-time-us)
  print "--- $(%06d duration.in-ms): $message"

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
  ui.emit --verbose "Running $toit-exe $args"
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

  board1 := TestDevice --name="board1" --port-path=port-board1 --ui=ui --toit-exe=toit-exe
  board2/TestDevice? := null

  try:
    board1-ready := monitor.Latch

    task::
      log "Connecting to board1"
      board1.connect-network
      log "Installing test on board1"
      board1.install-test test-path arg
      log "Board1 ready"
      board1-ready.set true

    if port-board2:
      board2 = TestDevice --name="board2" --port-path=port-board2 --ui=ui --toit-exe=toit-exe
      log "Connecting to board2"
      board2.connect-network
      log "Installing test on board2"
      board2.install-test test2-path arg
      log "Board2 ready"

    board1-ready.get
    log "Running test"
    board1.run-test
    if port-board2:
      board1.running-container.get
      board2.run-test

    ui.emit --verbose "Waiting for all tests to be done"
    board1.all-tests-done.get
    log "Board1 done"
    if board2:
      board2.all-tests-done.get
      log "Board2 done"

  finally:
    board1.close
    if board2: board2.close

class TestDevice:
  static SNAPSHOT-NAME ::= "test.snap"
  name/string
  port/uart.HostPort? := ?
  toit-exe/string
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

  constructor --.name --.toit-exe --port-path/string --.ui:
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
          std-out := data-str.replace --all "\n" "\n$(%06d timestamp.in-ms)-$name: "
          stdout.write std-out
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
            ui.abort "Error detected"

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
    // Reset the device.
    ui.emit --verbose "Resetting $name"
    port.set-control-flag uart.HostPort.CONTROL-FLAG-DTR false
    port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS true
    is-active = true
    sleep --ms=200
    port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS false

    ui.emit --verbose "Waiting for $name to be ready"
    ready-latch.get
    ui.emit --verbose "Device $name is ready"

    lines/List := collected-output.split "\n"
    lines.map --in-place: it.trim
    listening-line-index := lines.index-of --last MINI-JAG-LISTENING
    host-port-line := lines[listening-line-index - 1]
    parts := host-port-line.split ":"
    network_ = net.open
    socket_ = network_.tcp-connect parts[0] (int.parse parts[1])
    ui.emit --info "Connected to $host-port-line"

  disconnect-network:
    if socket_: socket_.close
    socket_ = null
    if network_: network_.close
    network_ = null

  install-test test-path arg/string:
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
    image := file.read-contents image-path

    log "Sending test to device"
    socket_.out.little-endian.write-int32 arg.size
    socket_.out.write arg
    socket_.out.little-endian.write-int32 image.size

    summer := crc.Crc32
    summer.add image
    socket_.out.write summer.get
    socket_.out.write image

    log "Waiting for test to be fully installed"
    installed-container.get

  run-test -> none:
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

