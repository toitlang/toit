// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I1:
class MyClass extends Base implements I1:
/*
        ^
  5
*/
class Base:

test type/MyClass -> MyClass:
/*
            ^
  5
*/
/*
                       ^
  5
*/
  t := MyClass
/*
         ^
  5
*/
  return t

main:
  test MyClass
