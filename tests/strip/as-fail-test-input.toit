// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x/int:
  print x

main args:
  local/any := 3
  if args.size != 5: local = "str"
  if args.size != 7:
    foo local
