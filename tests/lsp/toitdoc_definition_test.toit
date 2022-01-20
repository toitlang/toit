// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .toitdoc_definition_test as prefix

class SomeClass:
/*    @ SomeClass */

  member foo:
/*@ member */

  member --named:
/*       @ named */

  member2 x:
/*@ member2x */

  member2 x y:
/*@ member2xy */

  field := null
/*@ field */

  setter= val:
/*@ setter */

  super_target1:
/*@ super_target1 */

  super_target1 x:
/*@ super_target1x */

  super_target2 x y:
/*@ super_target2 x y*/

class SomeClass2 extends SomeClass:
/*    @ SomeClass2 */

  constructor:
/*@ unnamed-constructor */

  constructor.named:
/*@ named-constructor */

  /** $member2 */
/*         ^
  [member2x, member2xy]
*/
  foo:

  /** $(member2 x) */
/*         ^
  [member2x]
*/
  foo2:

  /** $super */
  /*    ^
    [super_target1, super_target1x]
  */
  super_target1:

  /** $(super) */
  /*    ^
    [super_target1]
  */
  super_target1 x:

  /** $(super x) */
  /*     ^
    [super_target1x]
  */
  super_target1 x y:

  /** $super */
  /*     ^
    [super_target2xy]
  */
  super_target2:

  /** $this */
  /*     ^
    [SomeClass2]
  */
  this_target:

/** $this */
/*    ^
  [ThisClass]
*/
class ThisClass:
/*    @ ThisClass */

/** $SomeClass */
/*    ^
  [SomeClass]
*/
foo1:

/** $SomeClass.constructor */
/*                  ^
  [SomeClass]
*/
foo2:

/** $SomeClass.member2 */
/*              ^
  [member2x, member2xy]
*/
foo3:

/** $SomeClass.field */
/*              ^
  [field]
*/
foo4:

/** $SomeClass.setter= */
/*              ^
  [setter]
*/
foo5:

/** $SomeClass2.constructor */
/*                ^
  [unnamed-constructor]
*/
foo6:

/** $SomeClass2.named */
/*              ^
  [named-constructor]
*/
foo7:

/** $(SomeClass.constructor) */
/*                  ^
  [SomeClass]
*/
foo8:

/** $(SomeClass.member2 x) */
/*              ^
  [member2x]
*/
foo9:

/** $(SomeClass.member2 x y) */
/*              ^
  [member2xy]
*/
foo10:

/** $(SomeClass.field) */
/*              ^
  [field]
*/
foo11:

/** $(SomeClass.field= val) */
/*              ^
  [field]
*/
foo12:

/** $(SomeClass.setter= val) */
/*              ^
  [setter]
*/
foo13:

/** $(SomeClass2.constructor) */
/*                ^
  [unnamed-constructor]
*/
foo14:

/** $(SomeClass2.named) */
/*               ^
  [named-constructor]
*/
foo15:

/** $x */
/*   ^
  [param1x]
*/
param1 x:
/*     @ param1x */

/** $named */
/*    ^
  [param2named]
*/
param2 --named:
/*     @ param2named */

/** $block */
/*    ^
  [param3block]
*/
param3 [block]:
/*     @ param3block
*/

/** $named_block */
/*    ^
  [param4named_block]
*/
param4 [--named_block]:
/*     @ param4named_block */

