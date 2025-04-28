// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.ubjson
import expect show *
import host.file
import .util show EnvelopeTest with-test

main args:
  with-test args: | test/EnvelopeTest |
    CONFIG ::= ubjson.encode #[1, 2, 3]
    test.extract-to-dir --dir-path=test.tmp-dir --config=CONFIG
    written-config := "$test.tmp-dir/ota0/config.ubjson"
    expect-equals CONFIG (file.read-contents written-config)
