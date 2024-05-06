// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  __Protected_
  __protected_
  __protected-global_++
  __protected-global_
  __protected-global-getter-setter_
  __protected-global-getter-setter_ = 499
  __protected-global-getter-setter_ += 4
  Protected_.__
  Protected_.__named

  Lambda.__ 499 1
  LazyInitializer_.__ 42
