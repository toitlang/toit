// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

fun --named --named2: return named + named2

class SomeClass:
  member --foo --bar: return foo + bar

main:
  fun --named=499
/*      ^~~~~~~~~
  + named=, named2=
  - *
*/
    --named2=42
/*    ^~~~~~~~~
  + named2=
  - foo, bar, foo=, bar=, fun
*/

  some := SomeClass
  some.member --foo=499
/*              ^~~~~~~
  + foo=, bar=
  - *
*/
    --bar=42
/*    ^~~~~~
  + bar=
  - named=, named2=, named, named2
*/
