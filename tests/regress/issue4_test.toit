// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// https://github.com/toitware/toit/issues/4

// This test makes sure the main process terminates before the hatched process.
main:
  hatch_::
    task:: sleep --ms=100
