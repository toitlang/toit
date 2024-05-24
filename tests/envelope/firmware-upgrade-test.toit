// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.sha256
import expect show *
import host.file
import .util show EnvelopeTest with-test

main args:
  with-test args: | test/EnvelopeTest |
    with-test args: | test2/EnvelopeTest |
      test2.install --name="hello" --source="""
        main: print "hello world!"
        """
      test2.extract-to-dir --dir-path="$test.tmp-dir/update"

    test.install --name="update" --source-path="./firmware-upgrade-source.toit"
    ota0 := "$test.tmp-dir/ota0"
    ota1 := "$test.tmp-dir/ota1"
    test.extract-to-dir --dir-path=ota0

    update-bits-path := "$test.tmp-dir/update/bits.bin"

    exit-code := test.run --ota-active=ota0 --ota-inactive=ota1 --allow-fail --env={
      "TOIT_FIRMWARE_TEST_PATH": update-bits-path
    }
    expect-equals 17 exit-code
    output := test.backticks --ota-active=ota1 --ota-inactive=ota0
    expect (output.contains "hello world!")
