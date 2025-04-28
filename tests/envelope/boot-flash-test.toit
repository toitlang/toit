// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .exit-codes
import .util show EnvelopeTest with-test

main args:
  with-test args: | test/EnvelopeTest |
    test.install --name="flash" --source-path="./boot-flash-source.toit"
    test.extract-to-dir --dir-path=test.tmp-dir
    output := test.boot-backticks test.tmp-dir
    expect (output.contains "Test succeeded")
