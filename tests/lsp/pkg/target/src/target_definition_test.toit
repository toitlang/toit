// Copyright (C) 2021 Toitware ApS. All rights reserved.

import foo.target2 as foo
/*              ^
  [target2_module]
*/

import foo.target2 as pre
/*      ^
  [target2_module]
*/

// import_for_locations ...target2.src.target2
