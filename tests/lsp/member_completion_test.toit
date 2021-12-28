// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .completion_imported
import .completion_imported as prefix

class C1:
  member1:
  member2:
    member1
/*  ^~~~~~~
  + member1, member2
*/
