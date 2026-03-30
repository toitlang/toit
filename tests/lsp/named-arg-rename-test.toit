// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .named-arg-rename-test-dep

main:
  foo --named_arg=42
/*      @ named-arg-call */
  baz --other_arg="hello"
/*      @ other-arg-call */
  bar --flag
/*      @ flag-call */
  obj := MyClass --value=42 --scale=2
/*                            @ scale-call */
