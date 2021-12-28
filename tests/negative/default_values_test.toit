// Copyright (C) 2019 Toitware ApS. All rights reserved.

// Once there is a default value, all must be default.
foo x=499 y:
  return x + unresolved

main:
  foo 1 2
