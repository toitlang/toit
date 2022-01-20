// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .completion_imported
import .completion_imported as prefix

class C1:
interface I1:

class C2 extends C1:
/*               ^~~
  + C1, ImportedClass, prefix
  - I1
*/

class C3 extends prefix.ImportedClass:
/*                      ^~~~~~~~~~~~~~
  + ImportedClass
  - *
*/

class C4 implements I1:
/*                  ^~~
  + I1, ImportedInterface, prefix
  - C1
*/

class C5 implements prefix.ImportedInterface:
/*                         ^~~~~~~~~~~~~~~~~~
  + ImportedInterface
  - *
*/
  imported_member:

interface I2 extends I1:
/*                   ^~~
  + I1, I3, I4, I5, ImportedInterface, prefix
  - C1, I2
*/

interface I3 extends prefix.ImportedInterface:
/*                          ^~~~~~~~~~~~~~~~~~
  + ImportedInterface
  - *
*/


interface I4 implements I1:
/*                      ^~~
  + I1, I2, I3, I5, ImportedInterface, prefix
  - C1, I4
*/

interface I5 implements prefix.ImportedInterface:
/*                             ^~~~~~~~~~~~~~~~~~
  + ImportedInterface
  - *
*/
  imported_member
