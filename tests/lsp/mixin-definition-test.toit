// Copyright (C) 2013 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.


mixin M1:
  foo:
/*@ M1_foo */

class A extends Object with M1:
  foo:
/*@ A_foo */

foo:
  a/M1 := A
  a.foo
/*   ^
  [M1_foo]
*/

  a.stringify
/*   ^
  [core.objects.Object.stringify]
*/

  a2 := A
  a2.foo
/*   ^
  [A_foo]
*/
