// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .static_completion_test as prefix

class Foo:
  static bar:
  member:

class Foo2:
  constructor: return Foo2 0
  constructor x:

  static statik:
  member:

class Gee:
  constructor x:
  static statik:
  member:

class Gee2:
  constructor x: return Gee2 1 2
  constructor x y:

  static statik:
  member:

bar2:

main:
  Foo.bar
/*    ^~~
  + bar
  - bar2, member
*/

  (Foo).member
/*      ^~~~~~
  + member
  - bar, bar2
*/

  prefix.Foo.bar
/*           ^~~
  + bar
  - bar2, member
*/

  (prefix.Foo).member
/*             ^~~~~~
  + member
  - bar, bar2
*/

  Foo2.statik
/*     ^~~~~~
  + statik
  - bar2, member
*/

  prefix.Foo2.statik
/*            ^~~~~~
  + statik
  - bar2, member
*/

  Gee.statik
/*    ^~~~~~
  + statik
  - bar2, member
*/

  prefix.Gee.statik
/*           ^~~~~~
  + statik
  - bar2, member
*/

  Gee2.statik
/*     ^~~~~~
  + statik
  - bar2, member
*/

  prefix.Gee2.statik
/*            ^~~~~~
  + statik
  - bar2, member
*/
