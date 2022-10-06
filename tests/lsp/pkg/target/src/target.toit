// Keep this comment, as '@ target_module' needs a line to point to.
/*
@ target_module
*/

// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

identify: return "target pkg"

target_global := 499
target_global_ := 42

class TargetClass_:
  field := 42
  field_ := 499

  constructor.named:
  constructor.named_:

  static statik:
  static static_:
  static static_field := 42
  static static_field_ := 499

  member:
  member_:

func:
func_:

interface TargetInterface_:
