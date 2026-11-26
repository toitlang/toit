// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The fixture of v2-verdict-policy-test.cc: calls spawn, which the trusted
// policy allows and the untrusted one denies.

main:
  print (spawn-it 0 1 2)

spawn-it a b c:
  #primitive.core.spawn: | e | return "failed $e"
