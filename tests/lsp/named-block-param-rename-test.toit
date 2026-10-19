// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

test [--on-done]:
/*
        @ def
           ^
  [def, usage, call]
*/
  on-done.call
/*
  @ usage
    ^
  [def, usage, call]
*/

main:
  test --on-done=: print "hello"
/*
         @ call
           ^
  [def, usage, call]
*/
