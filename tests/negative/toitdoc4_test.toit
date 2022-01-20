// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
$super
$(super)
*/
class A:
  foo:

/**
$super
$(super)
$(this)
*/
class B extends A:
  /**
  $(super x)
  $(this)
  */
  foo:

/// $(setter= x y)
setter= x y:
