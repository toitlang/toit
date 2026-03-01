// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x:
/*
^
[4:0]-[4:3]
[4:0]-[10:10]
*/
  return x
/*
  ^
[10:2]-[10:8]
[10:2]-[10:10]
[4:0]-[10:10]
*/
