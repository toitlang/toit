// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import monitor
import system.external

EXTERNAL-ID ::= "toit.io/external-test"

// Test that strings are 0-terminated on the C side.
main:
  client := external.Client.open EXTERNAL-ID

  strings := [
    "",
    "foo",
    "bar",
    "foobar",
    "foobar" * 100,
    "foobar" * 1000,
    "foo"[3..],
    "foobar"[3..],
    ("foobar" * 1000)[1..],
  ]
  strings.do: | str/string |
    response/ByteArray := client.request 0 str
    expect-equals (str.size + 1) response.size
    expect-equals 0 response.last
