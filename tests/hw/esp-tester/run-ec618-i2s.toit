// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import expect show *
import uart
import .tester as tester
import .shared
import ..ec618.run-bus-rig as relay
import ..shared.i2s-run-output
import ..shared.i2s-coordinator

// Run from the repository root under the shared rig lock. The S3 must already
// have the matching I2S peer installed; this never changes firmware.
main args:
  tester.start-time-us = Time.monotonic-us
  command := cli.Command "run-ec618-i2s"
      --options=[
        cli.Option "port" --help="Persistent EC618 UART0 console path.",
        cli.Option "peer-port" --help="Persistent S3 fixture console path.",
        cli.Option "toit-exe" --help="Toit executable used to compile containers.",
        cli.Option "expected-base" --help="Required EC618 base identity.",
        cli.Option "case" --help="rate,bits,format,master-or-slave,slots (duplex requires stereo=0)",
        cli.Option "direction" --default="rx" --help="EC618 transfer direction: rx, tx or duplex.",
        cli.Option "buffer-duration-ms" --help="Explicit EC618 duplex buffer duration (1–1000 ms).",
        cli.Option "capture-seconds" --help="Duplex capture length (1–10 seconds; default 2).",
        cli.Flag "tx-no-stall" --help="Transmit with default buffering and no deliberate producer pause.",
        cli.Flag "sensor-disconnected" --help="Confirm DS18B20 DQ is disconnected from BCLK.",
      ]
      --run=:: run it
  command.run args

run invocation/cli.Invocation:
  ["port", "peer-port", "toit-exe", "expected-base", "case"].do: |option/string|
    if not invocation[option]: invocation.cli.ui.abort "Missing --$option"
  if not invocation["sensor-disconnected"]:
    invocation.cli.ui.abort "Confirm disconnected DS18B20 DQ with --sensor-disconnected"
  parts := invocation["case"].split ","
  expect-equals 5 parts.size
  rate := int.parse parts[0]
  bits := int.parse parts[1]
  format := int.parse parts[2]
  role := parts[3]
  slots := int.parse parts[4]
  direction := invocation["direction"]
  expect (["rx", "tx", "duplex"].contains direction)
  transmit := direction == "tx"
  duplex := direction == "duplex"
  no-stall := invocation["tx-no-stall"]
  if no-stall and not transmit:
    invocation.cli.ui.abort "--tx-no-stall requires --direction=tx"
  expect 0 < rate <= 96_000
  expect ([8, 16, 24, 32].contains bits)
  expect 0 <= format <= 2
  expect (["master", "slave"].contains role)
  expect (transmit ? 0 <= slots <= 5 : ([0, 4, 5].contains slots))
  if duplex: expect-equals 0 slots
  duration/int? := null
  if value := invocation["buffer-duration-ms"]:
    if not duplex: invocation.cli.ui.abort "--buffer-duration-ms requires --direction=duplex"
    duration = int.parse value
    if not 1 <= duration <= 1000: invocation.cli.ui.abort "Buffer duration must be 1–1000 ms"
  capture-seconds/int? := null
  if value := invocation["capture-seconds"]:
    if not duplex: invocation.cli.ui.abort "--capture-seconds requires --direction=duplex"
    capture-seconds = int.parse value
    if not 1 <= capture-seconds <= 10: invocation.cli.ui.abort "Capture length must be 1–10 seconds"
  master := role == "master"
  source := "$rate $bits $format $(master ? "slave" : "master")"
  if transmit or duplex: source += " $slots $direction"
  if capture-seconds: source += " $capture-seconds"
  configuration := "master=$master rate=$rate bits=$bits format=$format slots=$slots"
  if duration: configuration += " buffer_ms=$duration"
  if capture-seconds: configuration += " capture_s=$capture-seconds"
  verdict := I2sRunOutput configuration
      --transmit=transmit
      --duplex=duplex
  tester.with-tmp-dir: |directory/string|
    preflight := tester.compile-test-image invocation["toit-exe"] "tests/hw/ec618/rig-preflight-ec618.toit"
        --tmp-dir=directory
        --ui=invocation.cli.ui
    program := duplex ? "duplex" : (transmit ? "transmit" : "receive")
    receiver := tester.compile-test-image invocation["toit-exe"] "tests/hw/ec618/i2s-$(program)-ec618.toit"
        --tmp-dir=directory
        --ui=invocation.cli.ui
    ec := tester.Ec618Link --port-path=invocation["port"] --fast-baud=115200
    try:
      ec.handshake
      health ec preflight invocation["expected-base"]
      peer := uart.HostPort invocation["peer-port"] --baud-rate=115200
      try:
        relay.wait-for-target peer.in peer.out
        identity := duplex ? "EC618-I2S-DUPLEX-v1" : (transmit ? "EC618-I2S-SINK-v1" : "EC618-I2S-SOURCE-v1")
        exchange peer "IDENTIFY" identity
        // Recover a previous interrupted invocation before preparing pins.
        exchange peer "STOP" "OK"
        recover := ::
          // Outlast both partial-upload recovery and the agent's test lease
          // before attempting another command after an uncertain failure.
          sleep --ms=17_000
        cancel := ::
          ec.send CMD-CANCEL
          ec.expect "CANCEL" ACK-OK --timeout-ms=3000
        argument := invocation["case"] + ((transmit or duplex) ? ",$direction" : "")
        if no-stall: argument += ",no-stall"
        if duration: argument += ",$duration"
        if capture-seconds:
          if not duration: argument += ",default"
          argument += ",$capture-seconds"
        peer-result := (transmit or duplex) ? "VERIFIED $rate $bits $format $slots $direction" : null
        if capture-seconds: peer-result += " capture_s=$capture-seconds"
        run-case ec verdict receiver argument source
            --exchange=(:: |command/string expected/string| exchange peer command expected)
            --cancel=cancel
            --recover=recover
            --health=(:: health ec preflight invocation["expected-base"])
            --peer-result=peer-result
        print "EC618 paired I2S $direction PASS: $(invocation["case"])"
      finally:
        peer.close
    finally:
      ec.close

exchange peer/uart.HostPort command/string expected/string:
  with-timeout --ms=5000:
    peer.out.write "$command\n" --flush
    require-peer-reply expected (relay.read-reply peer.in)

health ec/tester.Ec618Link image/ByteArray base/string:
  ec.handshake --attempts=3
  ec.send-arg base
  ec.install-container image
  if not (ec.run --timeout-ms=30_000): throw "EC I2S health check failed"
