// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .outline as prefix

// vvv Class
/**
With comments
*/
// other comments
class Class:
  foo: 499
// ^^^

// vvv bar
// Also with comments.
bar:
  return 499
// ^^^

class C:
  // vvv gee
  /// Field with comments.
  /// And more comments.
  gee := 499
  // ^^^

  // Detached comments don't count.

  // vvv foobar
  // Method with comments.
  foobar:
    return 499
  // ^^^

// vvv D --to-end.
class D:
  constructor x y:

  ignored-foo:

  ignored-bar:

  static ignored-static-method:

  ignored-field := 0
