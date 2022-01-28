// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

toto:

foo x y:
  #primitive.core.array_new
/*           ^~~~~~~~~~~~~~
  + core, crypto, intrinsics
  - toto, x, y
*/

bar x y:
  #primitive.core.array_new
/*                ^~~~~~~~~
  + array_new, array_replace
  - toto, x, y
*/

gee [b]:
  #primitive.intrinsics.array_do
/*                      ^~~~~~~~
  + array_do, smi_repeat
  - toto, x, y
*/

