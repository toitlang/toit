// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .import-no-exit-a show ambiguous
import .import-no-exit-b show ambiguous
import .import-no-exit-a show ambiguous-unresolved
import .import-no-exit-b show ambiguous-unresolved
import .nonexisting show ambiguous-unresolved
import .nonexisting show ambiguous-unresolved

import .import-no-exit-a show toplevel
import .import-no-exit-a show toplevel2
import .import-no-exit-a show Toplevel3

import .import-no-exit-a as pre  // Used in export below.
import .import-no-exit-a as prefix
import .import-no-exit-b show prefix

import .import-no-exit-c show *  // Used in export below.
import .import-no-exit-d show *  // Used in export below.

import .import-no-exit-a as toplevel
import .import-no-exit-a as toplevel2
import .import-no-exit-a as Toplevel3

import .import-no-exit-cycle1

export pre
export ambiguous-cd
export unresolved
export bad
export *    // Should report an error, but doesn't because of all the other errors.

toplevel := null
toplevel2: return null
class Toplevel3:

main:
  unresolved
  1.foo

