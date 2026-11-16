// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import zlib

main:
  // Test whether support is compiled into the VM.
  decoder := null
  catch: decoder = zlib.Decoder
  if not decoder:
    print "Zlib support is not compiled in."
    return

  // Corrupt input is an invalid argument (and is not reported on stdout).
  expect-throw "INVALID_ARGUMENT":
    decoder.out.write #[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
