// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
