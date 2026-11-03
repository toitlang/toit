// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a parameter of a `finally` block must not touch the other
//   parameter.
two-params:
  try:
    print 1
  finally: |is-exception exception|
/*
            @ a-def
            ^
  [a-def, a-use]
*/
/*
                         @ b-def
                         ^
  [b-def, b-use]
*/
    print is-exception
/*
          @ a-use
          ^
  [a-def, a-use]
*/
    print exception
/*
          @ b-use
          ^
  [b-def, b-use]
*/

typed:
  try:
    print 1
  finally: |is-exception/bool exception/any|
/*
            @ c-def
            ^
  [c-def, c-use]
*/
/*
                              @ d-def
                              ^
  [d-def, d-use]
*/
    print is-exception
/*
          @ c-use
          ^
  [c-def, c-use]
*/
    print exception
/*
          @ d-use
          ^
  [d-def, d-use]
*/

main:
  two-params
  typed
