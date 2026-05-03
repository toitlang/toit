// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .prefixed-class-in-static-call-hover-test as prefix

/**
Doc for Foo.
*/
class Foo:
  static bar -> int:
    return 42

main:
  prefix.Foo.bar
/*         ^
Doc for Foo.
*/
