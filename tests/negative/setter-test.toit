// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

setter=: unresolved
setter= x y: unresolved

class A:
  static-setter=: unresolved
  static-setter= x y: unresolved

  instance-setter=: unresolved
  instance-setter= x y: unresolved

main:
  setter = 3
  A.static-setter = 5
  A.instance-setter = 7
