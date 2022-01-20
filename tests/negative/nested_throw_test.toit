// Copyright (C) 2022 Toitware ApS. All rights reserved.

// Tests the entire process exits with exit value 1.
main:
  task::
    task::
      task:: throw "oops"
