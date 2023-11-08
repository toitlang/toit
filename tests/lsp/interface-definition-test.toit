// Copyright (C) 2013 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I1:
  foo
/*@ M1_foo */

class A implements I1:
  foo:
/*@ A_foo */

foo:
  a/I1 := A
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
