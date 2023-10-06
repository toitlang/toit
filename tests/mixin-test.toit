// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

mixin MixA:
  a_method: return 42

mixin MixB extends MixA:
  b_method: return 42

abstract mixin MixC extends MixB:
  abstract c_method -> int

main:
