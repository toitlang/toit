// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

run x [block]: block.call x

run x fun/Lambda: fun.call x

main:
  run 499: |it/string|
    it.copy 1
