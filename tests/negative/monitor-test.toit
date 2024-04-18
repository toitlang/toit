// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Bar:
  bar:
    print "bar"

monitor Foo Bar:
  foo:
    print "foo"

main:
  foo := Foo
