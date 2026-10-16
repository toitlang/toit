// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

after-bracket [b] /int: null
missing-bracket [b int -> bool: null
none-parameter [b none -> none]: null
unresolved [b Foo -> Bar]: null
nullable-return [b int -> bool?]: null
double-arrow [b -> -> int]: null
default-with-type [b = 5 int -> int]: null
empty-return [b int -> ]: null
nested [b [c]]: null
colon-after-type [b int: null

main:
  after-bracket: null
  missing-bracket: true
  none-parameter: null
  unresolved: null
  nullable-return: null

unterminated-at-eof [b int ->
