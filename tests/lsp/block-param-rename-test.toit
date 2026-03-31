// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

test [block-param]:
/*
      @ def
        ^
  [def, usage]
*/
  block-param.call
/*
  @ usage
    ^
  [def, usage]
*/

main:
  test: print "hello"
