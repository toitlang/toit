// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Foo extends Object with Gee implements Bar:
  abstract constructor:
  abstract constructor.factory:
    return Foo

interface Bar:
  abstract constructor:
  abstract constructor.factory:
    return Foo

mixin Gee:
  abstract constructor:
  abstract constructor.factory:
    return Foo

main:
