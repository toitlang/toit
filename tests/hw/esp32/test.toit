// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

ALL-TESTS-DONE ::= "All tests done."

run-test --background/bool=false [block]:
  // Background tests don't block the succesful completion of the tests.
  if background: print ALL-TESTS-DONE
  block.call
  if not background: print ALL-TESTS-DONE
