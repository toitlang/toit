// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo [block]: return block.call

global := return
global2 := foo: return 499
global3 := foo: return.global3 42
global4 := foo: continue.global4 42
