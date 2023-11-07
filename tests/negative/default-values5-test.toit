// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The type of the default value and the parameter must agree.
foo [x]=(499):
  return x

main:
  foo
  foo null
  foo: 1

