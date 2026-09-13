// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import io
import net
import uart

import .framed-control show FrameDecoder encode-frame

main args:
  command := cli.Command "run-bus-rig"
      --help="Relay framed EC618 control messages from the ESP32 TCP bridge to the target console."
      --options=[
        cli.Option "bridge" --required --help="Address of the ESP32 UART1 bridge.",
        cli.OptionInt "bridge-port" --default=18561 --help="TCP port of the bridge.",
        cli.Option "target-port" --help="Serial device path of the target fixture.",
        cli.Option "s3-port" --hidden --help="Alias for --target-port.",
      ]
      --run=:: run it
  command.run args

run invocation/cli.Invocation -> none:
  target-path := invocation["target-port"] or invocation["s3-port"]
  if not target-path: invocation.cli.ui.abort "Missing required option --target-port."
  target := uart.HostPort target-path --baud-rate=115200
  try:
    flags := target.read-control-flags
    target.set-control-flags flags & ~(uart.HostPort.CONTROL-FLAG-DTR | uart.HostPort.CONTROL-FLAG-RTS)
    // Restart the boot container after the previous run's QUIT, without
    // relying on a particular adapter's behavior when opening the port.
    target.set-control-flag uart.HostPort.CONTROL-FLAG-RTS true
    sleep --ms=500
    target.set-control-flag uart.HostPort.CONTROL-FLAG-RTS false
    wait-for-target target.in target.out
    network := net.open
    try:
      socket := with-timeout --ms=180_000:
        network.tcp-connect invocation["bridge"] invocation["bridge-port"]
      try:
        print "Coordinator ready"
        relay socket.in socket.out target.in target.out
      finally:
        socket.close
    finally:
      network.close
  finally:
    target.close

wait-for-target input/io.Reader output/io.Writer -> none:
  // Opening a USB-UART bridge can reset the fixture. Ignore boot output and
  // retry PING until its command handler is ready. Keep partial lines across retries.
  with-timeout --ms=15_000:
    while true:
      error := catch:
        with-timeout --ms=1_000:
          output.write "PING\n" --flush
          while true:
            if (read-reply input) == "READY": return
      if error != DEADLINE-EXCEEDED-ERROR: throw error

read-reply input/io.Reader -> string:
  while true:
    newline := input.index-of '\n'
    if newline < 0: throw "target console disconnected"
    line := (input.read-bytes newline).to-string-non-throwing.trim
    input.skip 1
    if line.is-empty: continue
    print "Target: $line"
    if line.starts-with "BUS-REPLY ": return line["BUS-REPLY ".size ..]

receive-command input/io.Reader decoder/FrameDecoder -> string:
  with-timeout --ms=180_000:
    while true:
      command := decoder.take
      if command != null: return command
      bytes := input.read
      if not bytes: throw "control bridge disconnected"
      decoder.add bytes
  unreachable

relay bridge-in/io.Reader bridge-out/io.Writer target-in/io.Reader target-out/io.Writer -> none:
  decoder := FrameDecoder
  while true:
    command := receive-command bridge-in decoder
    print "EC618 -> target: $command"
    with-timeout --ms=20_000:
      target-out.write "$command\n" --flush
      reply := read-reply target-in
      bridge-out.write (encode-frame reply) --flush
    if command == "QUIT": return
