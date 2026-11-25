// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that a host firmware runs the containers of its envelope with the
// flags the envelope gives them, as a device does. The host extraction puts
// the run-boot and the run-critical containers in startup-images/, and
// run-image used to install all of them run-boot and run-critical: a boot
// container became critical (its failure ended the system), and a critical
// one was started at boot.

import expect show *

import .util show EnvelopeTest with-test
import .installed-flags-source as source

main args:
  with-test args: | test/EnvelopeTest |
    test.install --name="installer" --source-path="./installed-flags-source.toit"
    test.install --name="booted" --boot --no-critical --source="""
      main: print "booted ran"
      """
    test.install --name="critical" --no-boot --critical --source="""
      main: print "critical ran"
      """
    test.install --name="bundled" --no-boot --source="""
      main: print "bundled ran"
      """
    test.extract-to-dir --dir-path=test.tmp-dir

    output := test.boot-backticks test.tmp-dir --env={source.ACTION: "list"}
    print output
    flags := []
    (output.split "\n").do: | line/string |
      if line.starts-with "image: ": flags.add line[44..].trim
    flags.sort --in-place
    expect-list-equals [
      "flags: 0 verified: 0 data: 0",  // bundled.
      "flags: 1 verified: 0 data: 0",  // booted.
      "flags: 2 verified: 0 data: 0",  // critical.
    ] flags
    expect (output.contains "booted ran")
    expect-not (output.contains "critical ran")
    expect-not (output.contains "bundled ran")
