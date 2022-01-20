// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo -> int:
  if true: return
  return 499

bar -> none:
  return 499

main:
  throw "negative"
