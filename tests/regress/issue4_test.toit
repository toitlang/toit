// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// https://github.com/toitware/toit/issues/4

// This test makes sure the main process terminates before the spawned process.
main:
  spawn::
    task:: sleep --ms=100
