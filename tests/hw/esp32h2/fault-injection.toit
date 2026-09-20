// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Negative tests: every mode must fail on the tester, with no TESTER PASS.
import expect show *
import .session

main args/List:
  mode := args[0]
  expect (["corrupt", "silent", "cleanup", "skip", "crash"].contains mode)
  session := Session
  try:
    session.run-case "Reject $mode testee" --ms=3000:
      if IS-TESTEE:
        if mode == "crash": throw "Injected testee crash"
        if mode == "cleanup": session.close
        if mode == "silent" or mode == "cleanup": sleep --ms=10000
        if mode == "skip": session.send ["finished", 0]
        if mode == "corrupt": session.send #[1, 2, 99]
      else:
        expect-equals #[1, 2, 3] session.receive
    session.finish
  finally:
    session.close
