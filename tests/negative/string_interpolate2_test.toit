// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Bad:
  stringify:
    return 499

main:
  bad := Bad
  str := "$bad"
