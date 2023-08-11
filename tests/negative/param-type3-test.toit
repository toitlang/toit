// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo str/string:
  return str

confuse x: return x

main:
  foo (confuse null)
