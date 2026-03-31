// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I1:
class MyClass extends Base implements I1:
/*
      @ def
        ^
  [def, param-type, return-type, local, instantiation]
*/
class Base:

test type/MyClass -> MyClass:
/*
          @ param-type
            ^
  [def, param-type, return-type, local, instantiation]
*/
/*
                     @ return-type
                       ^
  [def, param-type, return-type, local, instantiation]
*/
  t := MyClass
/*
       @ local
         ^
  [def, param-type, return-type, local, instantiation]
*/
  return t

main:
  test MyClass
/*     @ instantiation */
