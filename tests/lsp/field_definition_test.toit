// Copyright (C) 2020 Toitware ApS. All rights reserved.

class SomeClass:
  field := null
/*@ field */

  constructor:
    field
/*    ^
  [field]
*/

    field = 0
/*    ^
  [field]
*/

    field += 0
/*   ^
  [field]
*/

class SomeClass2 extends SomeClass:
  field: return 0
/*@ field2 */

  constructor:
    field
/*   ^
  [field, field2]
*/

    field = 0
/*   ^
  [field]
*/
    super

  constructor.named:
    field
/*    ^
  [field2]
*/

    field = 0
/*     ^
  [field]
*/

main:
