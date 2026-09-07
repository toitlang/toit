// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

inner value: value
outer value: value

sample a b c foo bar gee alpha beta:
  outer (inner 1)
  (a + b) * c
  foo or bar and gee
  (foo or bar) and gee
  alpha or
      beta

main:
  sample 1 2 3 true false true false true
