// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .completion-imported
import .completion-imported as prefix

class C1:
interface I1:
mixin Mix1:
mixin Mix1b:

class C2 extends C1:
/*               ^~~
  + C1, ImportedClass, prefix
  - I1, Mix1
*/

class C3 extends prefix.ImportedClass:
/*                      ^~~~~~~~~~~~~~
  + ImportedClass
  - *
*/

class C4 implements I1:
/*                  ^~~
  + I1, ImportedInterface, prefix
  - C1, Mix1
*/

class C5 implements prefix.ImportedInterface:
/*                         ^~~~~~~~~~~~~~~~~~
  + ImportedInterface
  - *
*/
  imported-member:

class C6 extends Object with Mix1:
/*                           ^~~~
  + Mix1, ImportedMixin, prefix
  - C1, I1, C6
*/

interface I2 extends I1:
/*                   ^~~
  + I1, I3, I4, ImportedInterface, prefix
  - C1, I2, Mix1
*/

interface I3 extends prefix.ImportedInterface:
/*                          ^~~~~~~~~~~~~~~~~~
  + ImportedInterface
  - *
*/

interface I4 implements prefix.ImportedInterface:
/*                             ^~~~~~~~~~~~~~~~~~
  + ImportedInterface
  - *
*/
  imported-member

mixin Mix2 extends Mix1:
/*                 ^~~~
  + Mix1, ImportedMixin, prefix
  - C1, I1, Mix2
*/

abstract mixin Mix3 extends prefix.ImportedMixin:
/*                                 ^~~~~~~~~~~~~
  + ImportedMixin
  - *
*/

mixin Mix4 extends Mix1 with Mix1b:
/*                           ^~~~~
  + Mix1b, ImportedMixin, prefix
  - C1, I1, Mix4
*/
