// Copyright (C) 2021 Toitware ApS. All rights reserved.

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
