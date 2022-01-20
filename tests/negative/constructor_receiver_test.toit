// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .constructor_receiver_test as pre

class A:
  constructor:
  constructor.named:

  member:

class B:
  constructor: return B.factory
  constructor.named: return B.factory
  constructor.factory:

  member:

main:
  A.member
  B.member

  pre.A.member
  pre.B.member

  // The following are ok.
  A.named.member
  B.named.member
  pre.A.named.member
  pre.B.named.member

  unresolved
