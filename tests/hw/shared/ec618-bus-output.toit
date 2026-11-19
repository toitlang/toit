// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class BusOutput:
  expected_/string
  pending_/string := ""
  passed/bool := false

  constructor case/string:
    expected_ = "FPC-FUNCTION $case PASS"

  accept text/string:
    pending_ += text
    while true:
      newline := pending_.index-of "\n"
      if newline < 0: break
      line := pending_[..newline].trim
      pending_ = pending_[newline + 1..]
      if line == expected_:
        if passed: throw "Duplicate FPC verdict"
        passed = true
    if pending_.size > 8192: throw "Oversized FPC output line"
