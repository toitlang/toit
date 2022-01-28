// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// No operators in default values.
foo x=5+3:
  return x

main:
  foo null
