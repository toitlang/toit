// Copyright (C) 2018 Toitware ApS. All rights reserved.

// https://github.com/toitware/toit/issues/4

// This test makes sure the main process terminates before the hatched process.
main:
  hatch_::
    task:: sleep --ms=100
