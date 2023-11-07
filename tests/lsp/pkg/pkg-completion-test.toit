// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import target
/*     ^~~~~~
  + core, target, target2
  - foo, identify
*/

import target.target as pre
/*            ^~~~~~~~~~~~~
  + target, target-completion-test
  - core, foo
*/

import target show *

private_ := 499

class Private_:
  field := 42
  field_ := 499

  constructor.named:
  constructor.named_:

  static statik:
  static static_:
  static static-field := 42
  static static-field_ := 499

  member:
  member_:

main:
  private_++
/*^~~~~~~~~~
  + identify, private_, fun, target-global
  - target-global_, TargetClass_, fun_
*/

  target.identify
/*       ^~~~~~~~
  + identify, fun, target-global
  - private_, target-global_, TargetClass_, fun_
*/

  local := 499
  local++
/*^~~~~
  + local, private_
  - target-global_, TargetClass_, fun_
*/

  local_ := 499
  local_++
/*^~~~~~
  + local, local_, private_
  - target-global_, TargetClass_, fun_
*/

  target-class := target.TargetClass_.named
/*                                    ^~~~~
  + named, statik, static-field
  - *
*/

  target-class.field++
/*             ^~~~~~~
  + field, member
  - field_, member_
*/

  p := Private_.named
/*              ^~~~~
  + named, named_, statik, static_, static-field, static-field_
  - *
*/

  p.field++
/*  ^~~~~~~
  + field, field_, member, member_
  - named, named_, statik, static_, static-field, static-field_
*/

gee -> target.TargetClass_?:
/*            ^~~~~~~~~~~~~
  - *
*/
  return null

bar -> bool:
/*     ^~~~
  + bool, Private_
  - TargetClass_, TargetInterface_
*/
  return true
