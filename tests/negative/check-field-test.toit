// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract x := unresolved

class A:
  abstract x := unresolved
  abstract static y := unresolved

interface B:
  x := unresolved
  abstract y := unresolved

interface C:
  constructor:
  x := unresolved
  abstract y := unresolved

main:
