// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import expect show *
import host.file
import .util show EnvelopeTest with-test

/**
Tests installing containers from source. The envelope keeps the sources,
  unless they are stripped, so they can be combined with the system program.
*/

main args:
  with-test args: | test/EnvelopeTest |
    source := "$test.tmp-dir/hello.toit"
    file.write-contents --path=source """
      main: print "hello from source"
      """
    test.firmware ["container", "install", "hello", source]
    test.firmware ["container", "install", "stripped", source, "--strip"]
    containers := list-containers test
    expect-equals true containers["hello"]["source"]
    expect-not (containers["stripped"].contains "source")

    // Without --combine, the containers run their snapshots.
    test.extract-to-dir --dir-path=test.tmp-dir
    output := test.backticks "$test.tmp-dir/ota0"
    expect (output.contains "hello from source")

    // Only ESP32 envelopes can combine containers.
    expect-equals 1 (test.firmware --allow-fail ["extract", "--combine", "--format", "tar", "-o", "$test.tmp-dir/x"])

    // Uninstalling drops the sources.
    test.firmware ["container", "uninstall", "hello"]
    containers = list-containers test
    expect-not (containers.contains "hello")
    expect-equals 0 (test.firmware --allow-fail ["container", "install", "hello", source, "--strip"])

list-containers test/EnvelopeTest -> Map:
  path := "$test.tmp-dir/containers.json"
  test.firmware ["container", "list", "-o", path]
  return json.decode (file.read-contents path)
