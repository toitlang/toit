// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
