// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface Base:
  abstract-method
/*@ abstract-def */
/*
  ^
  [abstract-def, impl, call]
*/

class Impl implements Base:
  abstract-method:
/*@ impl */
/*
  ^
  [abstract-def, impl, call]
*/
    return 42

main:
  i := Impl
  i.abstract-method
/*  @ call */
