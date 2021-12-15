// Copyright (C) 2020 Toitware ApS. All rights reserved.

run [block]:
run fun/Lambda:

foo _ _:
  // Underscores don't report duplicate parameter warnings.
  run: |_ _| 499
  run:: |_ _| 42

bar _/int _/string:
  return "ok"

main:
  foo 1 2
  bar 499 "str"
