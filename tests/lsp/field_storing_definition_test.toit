// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  field_A := null

  member -> any: return null
  member= val:

class B:
  field_B1 := null
/*@ field_B1 */
  field_B2 ::= null
/*@ field_B2 */
  field_B3 := ?
/*@ field_B3 */
  field_B4 ::= ?
/*@ field_B4 */
  field_B5 /int := 0
/*@ field_B5 */
  field_B6 /int ::= 0
/*@ field_B6 */

  constructor
      .field_B1
/*      ^
  [field_B1]
*/
      .field_B2
/*      ^
  [field_B2]
*/
      .field_B3
/*      ^
  [field_B3]
*/
      .field_B4
/*      ^
  [field_B4]
*/
      .field_B5
/*      ^
  [field_B5]
*/
      .field_B6:
/*      ^
  [field_B6]
*/

  constructor.named .field_B1:
/*                        ^
  [field_B1]
*/
    field_B2 = 0
    field_B3 = 0
    field_B4 = 0
    field_B5 = 0
    field_B6 = 0

  constructor.factory .field_B1:
/*                       ^
  [field_B1]
*/
    return B 1 2 3 4 5 6

  setter= val:

  member
      .field_B1
/*      ^
  [field_B1]
*/
      .field_B2
/*      ^
  [field_B2]
*/
      .field_B3
/*      ^
  [field_B3]
*/
      .field_B4
/*      ^
  [field_B4]
*/
      .field_B5
/*      ^
  [field_B5]
*/
      .field_B6:
/*      ^
  [field_B6]
*/

  static foo .field_B1:
/*              ^
  [field_B1]
*/

main:
