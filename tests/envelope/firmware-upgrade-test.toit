// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import .util show EnvelopeTest with-test

main args:
  with-test args: | test/EnvelopeTest |
    update-bits-path := "$test.tmp-dir/update-bits.bin"

    test.build-ota --output=update-bits-path --name="hello" --source="""
      main: print "hello world!"
      """

    test.install --name="update" --source-path="./firmware-upgrade-source.toit"
    ota0 := "$test.tmp-dir/ota0"
    ota1 := "$test.tmp-dir/ota1"
    test.extract-to-dir --dir-path=test.tmp-dir

    exit-code := test.run --ota-active=ota0 --ota-inactive=ota1 --allow-fail --env={
      "TOIT_FIRMWARE_TEST_PATH": update-bits-path
    }
    expect-equals 17 exit-code
    output := test.backticks --ota-active=ota1 --ota-inactive=ota0
    expect (output.contains "hello world!")
