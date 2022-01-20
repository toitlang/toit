// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface Inter:

class A:

class B implements Inter:

confuse x: return x

foo -> Inter:
  return confuse A

main:
  confuse A
  confuse B
  foo
