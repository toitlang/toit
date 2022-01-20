// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import foo.target2 as foo
/*              ^
  [target2_module]
*/

import foo.target2 as pre
/*      ^
  [target2_module]
*/

// import_for_locations ...target2.src.target2
