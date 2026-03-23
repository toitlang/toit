// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .named-arg-rename-test-dep

main:
  foo --named_arg=42
  foo --named_arg=7 --other_arg="hello"
  bar --flag
  obj := MyClass --value=42 --scale=2
