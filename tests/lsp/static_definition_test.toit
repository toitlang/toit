// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .static_definition_test as prefix

class Foo:
/*    @ Foo */
  static bar:
/*       @ bar */
  member:
/*@ member */

main:
  Foo.bar
/*     ^
  [bar]
*/

  (Foo).member
/*        ^
  [member]
*/

  Foo.bar.something
/*     ^
  [bar]
*/

  prefix.Foo.bar
/*            ^
  [bar]
*/

  (prefix.Foo).member
/*              ^
  [member]
*/

  prefix.Foo.bar.something
/*            ^
  [bar]
*/
