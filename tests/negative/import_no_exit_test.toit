// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .import_no_exit_a show ambiguous
import .import_no_exit_b show ambiguous
import .import_no_exit_a show ambiguous_unresolved
import .import_no_exit_b show ambiguous_unresolved
import .nonexisting show ambiguous_unresolved
import .nonexisting show ambiguous_unresolved

import .import_no_exit_a show toplevel
import .import_no_exit_a show toplevel2
import .import_no_exit_a show Toplevel3

import .import_no_exit_a as pre  // Used in export below.
import .import_no_exit_a as prefix
import .import_no_exit_b show prefix

import .import_no_exit_c show *  // Used in export below.
import .import_no_exit_d show *  // Used in export below.

import .import_no_exit_a as toplevel
import .import_no_exit_a as toplevel2
import .import_no_exit_a as Toplevel3

import .import_no_exit_cycle1

export pre
export ambiguous_cd
export unresolved
export bad
export *    // Should report an error, but doesn't because of all the other errors.

toplevel := null
toplevel2: return null
class Toplevel3:

main:
  unresolved
  1.foo

