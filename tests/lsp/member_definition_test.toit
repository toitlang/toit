// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .completion_imported
import .completion_imported as prefix

class C1:
  member1 x:
/*@ member1_1 */
  member1 x y:
/*@ member1_2 */

  member2:
    member1 1
/*    ^
  [member1_1]
*/

    member1 1 2
/*    ^
  [member1_2]
*/

    member1
/*    ^
  [member1_1, member1_2]
*/
