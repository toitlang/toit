// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import monitor
import net
import uart
import .tester as tester
import .shared
import ..ec618.run-bus-rig as relay
import ..shared.ec618-standalone
import ..shared.ec618-bus-output

// Run from the repository root under the shared rig lock. No firmware is flashed.
main args:
  tester.start-time-us = Time.monotonic-us
  command := cli.Command "run-ec618-bus"
      --options=[
        cli.Option "port" --required,
        cli.Option "target-port" --required,
        cli.Option "toit-exe" --required,
        cli.Option "expected-base" --required,
        cli.Option "bridge" --required,
        cli.OptionInt "bridge-port" --default=18561,
        cli.Option "case" --required,
      ]
      --run=:: run it
  command.run args

reset-target target/uart.HostPort:
  flags := target.read-control-flags
  target.set-control-flags flags & ~(uart.HostPort.CONTROL-FLAG-DTR | uart.HostPort.CONTROL-FLAG-RTS)
  target.set-control-flag uart.HostPort.CONTROL-FLAG-RTS true
  sleep --ms=500
  target.set-control-flag uart.HostPort.CONTROL-FLAG-RTS false
  relay.wait-for-target target.in target.out
  with-timeout --ms=5000:
    target.out.write "IDENTIFY\n" --flush
    actual := relay.read-reply target.in
    if actual != "FPC-BUS-1": throw "Wrong target fixture: $actual"

run invocation/cli.Invocation:
  case := invocation["case"]
  if not ["dual-i2c-matrix", "dual-i2c-fpc", "uart", "uart-alt", "spi"].contains case:
    invocation.cli.ui.abort "Unknown FPC test: $case"
  if invocation["expected-base"] == "": invocation.cli.ui.abort "Expected base must not be empty"
  if invocation["port"] == invocation["target-port"]:
    invocation.cli.ui.abort "EC618 and target ports must differ"
  if not 1 <= invocation["bridge-port"] <= 65535:
    invocation.cli.ui.abort "Invalid bridge port"
  tester.with-tmp-dir: |directory/string|
    preflight := tester.compile-test-image invocation["toit-exe"] "tests/hw/ec618/rig-preflight-ec618.toit"
        --tmp-dir=directory
        --ui=invocation.cli.ui
    program := tester.compile-test-image invocation["toit-exe"] "tests/hw/ec618/fpc-controller-ec618.toit"
        --tmp-dir=directory
        --ui=invocation.cli.ui
    ec := tester.Ec618Link --port-path=invocation["port"] --fast-baud=115200
    target/uart.HostPort? := null
    network/any := null
    socket/any := null
    worker/Task? := null
    try:
      health := ::
        ec.handshake --attempts=3
        ec.send-arg invocation["expected-base"]
        ec.install-container preflight
        if not (ec.run --timeout-ms=30_000): throw "EC618 health check failed"
      execute := ::
        network = net.open
        socket = with-timeout --ms=5000:
          network.tcp-connect invocation["bridge"] invocation["bridge-port"]
        // Drain stale UART control frames before starting the new controller.
        with-timeout --ms=3000:
          while true:
            quiet := false
            error := catch:
              with-timeout --ms=500:
                if not socket.in.read: throw "Control bridge disconnected"
            if error == DEADLINE-EXCEEDED-ERROR: quiet = true
            else if error: throw error
            if quiet: break
        target = uart.HostPort invocation["target-port"] --baud-rate=115200
        reset-target target
        done := monitor.Latch
        relay-error/any := null
        worker = task::
          relay-error = catch: relay.relay socket.in socket.out target.in target.out
          done.set null
        print "Coordinator ready"
        verdict := BusOutput case
        ec.send-arg case
        ec.install-container program
        success := ec.run --timeout-ms=240_000 --on-output=(:: |text/string| verdict.accept text)
        if not success: throw "FPC controller failed"
        if not verdict.passed: throw "Missing FPC controller verdict"
        with-timeout --ms=5000: done.get
        if relay-error: throw relay-error
        true
      cleanup := ::
        try:
          if worker: worker.cancel
          worker = null
          if socket: socket.close
          socket = null
        finally:
          if target: reset-target target
      cancel := ::
        ec.send CMD-CANCEL
        ec.expect "CANCEL" ACK-OK --timeout-ms=3000
      run-standalone --health=health --execute=execute --cancel=cancel
          --recover=(:: sleep --ms=17_000)
          --cleanup=cleanup
      print "FPC $case: controller, coordinator and final health PASS"
    finally:
      if worker: worker.cancel
      if socket: socket.close
      if target: target.close
      if network: network.close
      ec.close
