// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The following methods are private to the core library.
// They should not be used by user-code. We make sure that we do some checks.

main:
  run_global_initializer_ 10000 (LazyInitializer_ -2)
