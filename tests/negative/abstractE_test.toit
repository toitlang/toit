// Copyright (C) 2019 Toitware ApS. All rights reserved.

abstract class A:
  abstract foo

// Claims to be non-abstract.
class B extends A:

// Should not have any error message anymore.
class C extends B:

main:
  C  // Should not have any error message.
