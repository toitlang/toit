// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
