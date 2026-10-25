// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import .tester as tester
import .shared
import ..shared.ec618-standalone

// Run from the repository root under the shared rig lock.
main args:
  tester.start-time-us = Time.monotonic-us
  command := cli.Command "run-ec618-standalone"
      --options=[
        cli.Option "port" --required,
        cli.Option "toit-exe" --required,
        cli.Option "expected-base" --required,
        cli.Option "test" --required,
        cli.Option "arg" --default="",
        cli.OptionInt "timeout-ms" --default=90_000,
      ]
      --run=:: run it
  command.run args

run invocation/cli.Invocation:
  if invocation["timeout-ms"] <= 0:
    invocation.cli.ui.abort "Timeout must be positive"
  if invocation["expected-base"] == "":
    invocation.cli.ui.abort "Expected base must not be empty"
  tester.with-tmp-dir: |directory/string|
    preflight := tester.compile-test-image invocation["toit-exe"] "tests/hw/ec618/rig-preflight-ec618.toit"
        --tmp-dir=directory
        --ui=invocation.cli.ui
    program := tester.compile-test-image invocation["toit-exe"] invocation["test"]
        --tmp-dir=directory
        --ui=invocation.cli.ui
    ec := tester.Ec618Link --port-path=invocation["port"] --fast-baud=115200
    try:
      health := ::
        ec.handshake --attempts=3
        ec.send-arg invocation["expected-base"]
        ec.install-container preflight
        if not (ec.run --timeout-ms=30_000): throw "EC618 health check failed"
      execute := ::
        ec.send-arg invocation["arg"]
        ec.install-container program
        ec.run --timeout-ms=invocation["timeout-ms"]
      cancel := ::
        ec.send CMD-CANCEL
        ec.expect "CANCEL" ACK-OK --timeout-ms=3000
      run-standalone --health=health --execute=execute --cancel=cancel
          --recover=(:: sleep --ms=17_000)
      print "EC618 standalone PASS: $(invocation["test"])"
    finally:
      ec.close
