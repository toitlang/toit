// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

mixin A extends B:
mixin B extends A:

mixin C:
mixin D extends C with E:
mixin E extends C:

mixin F:
mixin G extends F with H:
mixin H extends F with G:

main:
