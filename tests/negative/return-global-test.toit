// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [block]: return block.call

global := return
global2 := foo: return 499
global3 := foo: return.global3 42
global4 := foo: continue.global4 42
