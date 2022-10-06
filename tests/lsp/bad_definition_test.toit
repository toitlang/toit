// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

func x:
/*
@ func
*/

func x y:
/*
@ func2
*/

class A:
  constructor:
/*@ A */

  constructor.single x:
/*@ A.single */

  constructor.named x:
/*@ A.named1 */
  constructor.named x y:
/*@ A.named2 */

  static foo x y:
/*       @ static_foo */

  static bar x:
/*       @ static_bar1 */
  static bar x y:
/*       @ static_bar2 */

class B:
  foo x:
/*@ B.foo1 */
  foo x y:
/*@ B.foo2 */

class C extends B:
  foo x:
/*@ C.foo1 */
  foo x y z:
/*@ C.foo3 */

main:
  func
/*^
  [func, func2]
*/

  A 499
/*^
  [A]
*/

  A.single
/*   ^
  [A.single]
*/

  A.named
/*   ^
  [A.named1, A.named2]
*/

  A.foo
/*   ^
  [static_foo]
*/

  A.bar
/*   ^
  [static_bar1, static_bar2]
*/

  A.fo
/*   ^
  []
*/

  A.name
/*   ^
  []
*/

  (A).fo
/*     ^
  []
*/

  (A).name
/*     ^
  []
*/

  c := C
  c.foo
/*   ^
  [C.foo1, C.foo3, B.foo2]
*/

  (C).foo
/*     ^
  [C.foo1, C.foo3, B.foo2]
*/

  C.foo
/*   ^
  [C.foo1, C.foo3, B.foo2]
*/
