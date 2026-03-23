// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

test [block-param]:
/*
        ^
  2
*/
  block-param.call
/*
    ^
  2
*/

main:
  test: print "hello"
