// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class SomeClass:
  field := null

  constructor:
    field
/*  ^~~~~
  + field
*/
    field
/*       ^
  + field
*/

    field = 0
/*  ^~~~~
  + field
*/
    field = 0
/*       ^
  + field
*/

    field += 0
/*  ^~~~~
  + field
*/
    field += 0
/*       ^
  + field
*/

class SomeClass2 extends SomeClass:
  constructor:
    field
/*  ^~~~~
  + field
*/
    field
/*       ^
  + field
*/

    field = 0
/*  ^~~~~
  + field
*/
    field = 0
/*       ^
  + field
*/
    super

  constructor.named:
    field
/*  ^~~~~
  + field
*/
    field
/*       ^
  + field
*/
    field = 0
/*  ^~~~~
  + field
*/
    field = 0
/*       ^
  + field
*/

main:
