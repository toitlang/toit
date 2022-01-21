// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract class A:
  abstract foo

// Claims to be non-abstract.
class B extends A:

// Should not have any error message anymore.
class C extends B:

main:
  C  // Should not have any error message.
