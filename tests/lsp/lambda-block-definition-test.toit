// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo:
/*@ A_foo */

main:
  a := A
/*@ a */
  a2 := A  // a2 is mutated.
/*@ a2 */
  if Time.now.utc.h == -1: a2 = A

  lambda := ::
    a.foo
/*     ^
  [A_foo]
*/
    a2.foo
/*     ^
  [A_foo]
*/
    a.foo
/*  ^
  [a]
*/
    a2.foo
/*   ^
  [a2]
*/

  block := :
    a.foo
/*     ^
  [A_foo]
*/
    a2.foo
/*     ^
  [A_foo]
*/
    a.foo
/*  ^
  [a]
*/
    a2.foo
/*   ^
  [a2]
*/
