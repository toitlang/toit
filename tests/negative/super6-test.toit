// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  :  // No name for method.
    // No error on super call since we already reported an error on the method name.
    super unresolved
    super = unresolved
