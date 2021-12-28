// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  foo:

bar:

main:
  a := A
  a2 := A  // a2 is mutated.
  if Time.now.utc.h == -2: a2 = A

  lamda := ::
    a.foo
/*    ^~~
  + foo
  - bar
*/

    a2.foo
/*     ^~~
  + foo
  - bar
*/

  block := :
    a.foo
/*    ^~~
  + foo
  - bar
*/

    a2.foo
/*     ^~~
  + foo
  - bar
*/
