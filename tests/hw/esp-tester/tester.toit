// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import crypto.crc
import fs
import host.directory
import host.file
import host.pipe
import monitor
import net
import system
import uart
import .shared

ALL-TESTS-DONE ::= "All tests done"
JAG-DECODE ::= "jag decode"

main args:
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

  board1 := TestDevice --name="board1" --port-path=port-board1 --ui=ui --toit-exe=toit-exe
  board2/TestDevice? := null

  try:
    board1.run-test test-path

    if port-board2:
      board2 = TestDevice --name="board2" --port-path=port-board2 --ui=ui --toit-exe=toit-exe
      board2.run-test test2-path

    ui.emit --verbose "Waiting for all tests to be done"
    board1.all-tests-done.get
    if board2: board2.all-tests-done.get

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
  all-tests-done/monitor.Latch := monitor.Latch
  ui/cli.Ui
  tmp-dir/string

  constructor --.name --.toit-exe --port-path/string --.ui:
    port = uart.HostPort port-path --baud-rate=115200
    tmp-dir = directory.mkdtemp "/tmp/esp-tester"
    read-task = task --background::
      try:
        reader := port.in
        stdout := pipe.stdout
        while data/ByteArray? := reader.read:
          if not is-active: continue
          stdout.write data
          collected-output += data.to-string-non-throwing
          if not ready-latch.has-value and collected-output.contains "\n$MINI-JAG-LISTENING":
            ready-latch.set true
          if not all-tests-done.has-value and collected-output.contains ALL-TESTS-DONE:
            all-tests-done.set true
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

  close:
    if read-task:
      read-task.cancel
    if file.is-directory tmp-dir:
      directory.rmdir --recursive tmp-dir

  toit_ args/List:
    run-toit toit-exe args --ui=ui

  run-test test-path:
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
    ui.emit --info "Running test on $host-port-line"

    snapshot-path := "$tmp-dir/$SNAPSHOT-NAME"
    toit_ [
      "compile",
      "--snapshot",
      "-o", snapshot-path,
      test-path
    ]

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

    network := net.open
    parts := host-port-line.split ":"
    socket := network.tcp-connect parts[0] (int.parse parts[1])
    socket.out.little-endian.write-int32 image.size
    summer := crc.Crc32
    summer.add image
    socket.out.write summer.get
    socket.out.write image
    socket.close

setup-tester invocation/cli.Invocation:
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

