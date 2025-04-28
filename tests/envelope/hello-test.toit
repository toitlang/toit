// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .util show EnvelopeTest with-test

main args:
  with-test args: | test/EnvelopeTest |
    test.install --name="hello" --source="""
      main: print "hello world"
      """
    test.extract-to-dir --dir-path=test.tmp-dir
    ota0 := "$test.tmp-dir/ota0"
    output := test.backticks ota0
    expect (output.contains "hello world")
