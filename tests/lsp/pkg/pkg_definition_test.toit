// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import target
/*       ^
  [target_module]
*/

import target.target as pre
/*       ^
  [target_module]
*/

import target.target as pre2
/*              ^
  [target_module]
*/

// import_for_locations .target.src.target

main:
  target.identify
