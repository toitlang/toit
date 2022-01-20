// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract class A:
  abstract foo x y=unresolved --named1=unresolved --named2=2
  // We would like to see a type error here, but that doesn't work right now.
  abstract bar x/int="str"
