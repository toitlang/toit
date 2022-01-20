// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

setter=: unresolved
setter= x y: unresolved

class A:
  static_setter=: unresolved
  static_setter= x y: unresolved

  instance_setter=: unresolved
  instance_setter= x y: unresolved

main:
  setter = 3
  A.static_setter = 5
  A.instance_setter = 7
