// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo: return false

main:
  if foo:
/*   ^~~~
  + foo
*/

  while foo:
/*      ^~~~
  + foo
*/

  for foo; foo; foo:
/*    ^~~~~~~~~~~~~~
  + foo
*/

  for foo; foo; foo:
/*         ^~~~~~~~~
  + foo
*/

  for foo; foo; foo:
/*              ^~~~
  + foo
*/

  x := foo ? foo : foo
/*     ^~~~~~~~~~~~~~~
  + foo
*/

  x = foo ? foo : foo
/*          ^~~~~~~~~
  + foo
*/

  y := (foo)
/*      ^~~~
  + foo
*/

  z := []
  z[foo]
/*  ^~~~
  + foo
*/

  try: foo finally: foo
/*     ^~~~~~~~~~~~~~~~
  + foo
*/
