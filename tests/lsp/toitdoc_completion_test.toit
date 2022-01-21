// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .toitdoc_completion_test as prefix
import .completion_imported as imported

global := 499

class SomeClass:
  member foo:
  member2 x:
  field := null
  setter= val:
  super_target1:

  static static_fun:
  static static_field := 499

class SomeClass2 extends SomeClass:
  constructor:
  constructor.named:

  /** $member2 */
/*     ^~~~~~~
  + this, foo, SomeClass, prefix, setter, field, global, param1
  - super, param2
*/
  foo param1:

  /** $member2 */
/*     ^~~~~~~
  + this, super, foo, SomeClass, prefix, setter, field, global, param2
*/
  member param2:


  /** $(member2 x) */
/*      ^~~~~~~~~
  + this, foo, SomeClass, prefix, setter, field, global, param1, block, named
  - super, param2
*/
  foo param1 [block] --named:

  /** $(member2 x) */
/*      ^~~~~~~~~
  + this, super, foo, SomeClass, prefix, setter, field, global, param2, block2, named
  - param1, block
*/
  member param2 [block2] --named:

  /** $member2 */
/*     ^~~~~~~
  + this, foo, SomeClass, prefix, setter, field, global, param1
  - super
*/
  static statik param1:

  /** $member2 */
/*     ^~~~~~~
  + this, foo, SomeClass, prefix, setter, field, global
  - super
*/
  static super_target1:

  /** $prefix.SomeClass */
  /*          ^~~~~~~~~
    + SomeClass, SomeClass2, global, bar1, bar2
    - *
  */
  foo1 param1:

  /** $imported.ImportedClass */
  /*            ^~~~~~~~~~~~~
    + ImportedClass, ImportedInterface
    - *
  */
  foo2 param1:

  // TODO(florian): not sure we should have "constructor"
  /** $SomeClass.static_field */
  /*             ^~~~~~~~~~~~
    + member, member2 field, setter, super_target1, static_fun, static_field, constructor
    - *
  */
  foo3 param1:

  // TODO(florian): not sure if we should have "constructor".
  /** $imported.ImportedClass.imported_member */
  /*                          ^~~~~~~~~~~~~~~
    - imported_member, imported_static_member, constructor
    - *
  */
  foo4 --named:


// TODO(florian): not sure we should have "constructor"
/** $SomeClass */
/*   ^~~~~~~~~
  + SomeClass, SomeClass2, prefix, global, param1
  - this, super, param2, foo, field, setter
*/
bar1 param1:

// TODO(florian): not sure if we should have "constructor".
/** $imported.ImportedClass.imported_member */
/*                          ^~~~~~~~~~~~~~~
  + imported_member, imported_static_member, constructor
  - *
*/
bar2 --named:
