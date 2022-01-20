// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [block]:
bar [block]:

gee fun/Lambda:

named [--name1] [--name2]:

class A:
  member [block]:

main:
  continue.foo
/*          ^
  []
*/

  foo:
/*   @ foo1 */
    continue.foo 499
/*            ^
  [foo1]
*/

  foo:
    foo:
/*     @ foo2 */
      continue.foo 499
/*              ^
  [foo2]
*/

  foo:
    bar:
/*     @ bar1 */
      continue.bar 499
/*              ^
  [bar1]
*/

  gee::
/*   @ gee1 */
    continue.gee
/*            ^
  [gee1]
*/

  named
    --name1=:
/*          @ name1 */
      continue.named
/*              ^
  [name1]
*/
    --name2=:
/*          @ name2 */
      continue.named
/*             ^
  [name2]
*/

  a := A
  a.member:
/*        @ member1 */
    continue.member
/*             ^
  [member1]
*/

  foo:
    a.member:
/*          @ member2 */
      continue.member
/*               ^
  [member2]
*/

  block := :
/*         @ block */
    continue.block
/*             ^
  [block]
*/

  lambda := ::
/*          @ lambda */
    continue.lambda
/*             ^
  [lambda]
*/

  foo:
/*   @ bad_foo */
    gee::
      continue.foo
/*              ^
  [bad_foo]
*/
