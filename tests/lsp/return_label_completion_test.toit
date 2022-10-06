// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [block]:
bar [block]:

gee func/Lambda:

named [--name1] [--name2]:

class A:
  member [block]:

main:
  continue.foo
/*          ^~
  +
  - *
*/

  foo:
    continue.foo 499
/*           ^~~~~~~
  + foo
  - *
*/

  foo:
    foo:
      continue.foo 499
/*             ^~~~~~~
  + foo
  - *
*/

  foo:
    bar:
      continue.bar 499
/*             ^~~~~~~
  + foo, bar
  - *
*/

  gee::
    continue.gee
/*           ^~~
  + gee
  - *
*/

  named
    --name1=:
      continue.named
/*             ^~~~~
  + named
  - *
*/
    --name2=:
      continue.named
/*             ^~~~~
  + named
  - *
*/


  a := A
  a.member:
    continue.member
/*           ^~~~~~
  + member
  - *
*/

  foo:
    a.member:
      continue.member
/*             ^~~~~~
  + foo, member
  - *
*/

  block := :
    continue.block
/*           ^~~~~
  + block
  - *
*/

  lambda := ::
    continue.lambda
/*           ^~~~~~
  + lambda
  - *
*/
