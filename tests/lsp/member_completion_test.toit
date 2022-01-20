// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .completion_imported
import .completion_imported as prefix

class C1:
  member1:
  member2:
    member1
/*  ^~~~~~~
  + member1, member2
*/
