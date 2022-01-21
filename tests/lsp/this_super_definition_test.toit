// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class SomeClass:
/*    @ SomeClass */

  field := null

  constructor:
/*@ SomeClass.SomeClass */
    this.field = 499
/*   ^
  [SomeClass]
*/

  constructor.named1:
/*@ SomeClass.named1 */

  constructor.named2 x:
/*@ SomeClass.named2x */

  constructor.named2 x y:
/*@ SomeClass.named2xy */

  foo:
/*@ SomeClass.foo */

  bar x:
/*@ SomeClass.barx */

  bar x y:
/*@ SomeClass.barxy */

  member:
    this.member
/*   ^
  [SomeClass]
*/

  static statik:
    this.member  // It's an error, but we might as well link to the class.
/*   ^
  [SomeClass]
*/

class Subclass extends SomeClass:
  constructor:
    super
/*     ^
  [SomeClass.SomeClass]
*/

  constructor x:
    super.named1
/*         ^
  [SomeClass.named1]
*/

  constructor x y:
    super.named2
/*         ^
  [SomeClass.named2x, SomeClass.named2xy]
*/

  constructor x y z:
    super.named2 1
/*         ^
  [SomeClass.named2x]
*/

  constructor x y z t:
    super.named2 1
/*     ^
  []
*/

  foo:
    super
/*    ^
  [SomeClass.foo]
*/

  bar:
    super 1
/*    ^
  [SomeClass.barx]
*/

    super
/*    ^
  [SomeClass.barx, SomeClass.barxy]
*/
