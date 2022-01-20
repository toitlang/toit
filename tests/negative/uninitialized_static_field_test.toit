// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  static static_field := ?

main args:
  if args.size == -1: A.static_field = 499
  print A.static_field
