// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .ambiguous_a as amb
import .ambiguous_b as amb
import .toitdoc_test as self

/**
"incomplete string
x
`incomplete code
y
*/

/**
```
incomplete code
*/
foo:

/**
  $(32 )
  $(id --)
  $(id -- x)
  $(id [-- x])
  $(id --[foo])
  $(
*/
gee:

/**
"foo
  bar
*/
toto:

/**
`foo
  bar
*/
titi:

/**
$(A.foo)
$(bar)
$(amb.foo)
$amb
$(for)
$(amb)
$foo =
$foo=
$(foo x y z)
$(foo=)
*/
class A:
  foo x:

  bar:
  bar:

/**
$(A.foo
*/
foo2:

/**
$(A.foo x
*/
foo3:

/**
$(A.bar x
*/
foo4:
