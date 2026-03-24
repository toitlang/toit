// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: constructor call (class name at instantiation).
class MyObj:
  constructor:

make-it:
  obj := MyObj
/*       ^
  MyObj
*/
  return obj

main:
  make-it
