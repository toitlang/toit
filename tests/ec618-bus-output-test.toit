// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .hw.shared.ec618-bus-output

main:
  marker := "FPC-FUNCTION uart PASS\n"
  marker.size.repeat: |split/int|
    output := BusOutput "uart"
    output.accept marker[..split]
    expect (not output.passed)
    output.accept marker[split..]
    expect output.passed
    error := catch: output.accept marker
    expect (error != null)
  ["FPC-FUNCTION uart-alt PASS\n", "FPC-FUNCTION uart PASS extra\n", "FPC-FUNCTION uart PASS"].do: |text/string|
    output := BusOutput "uart"
    output.accept text
    expect (not output.passed)
  output := BusOutput "uart"
  error := catch: output.accept ("x" * 8193)
  expect (error != null)
