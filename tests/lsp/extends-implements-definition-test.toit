// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition-imported
import .definition-imported as prefix

class C1:
/*    @ C1 */

interface I1:
/*        @ I1 */

mixin Mix1:
/*    @ Mix1 */

mixin Mix1b:
/*    @ Mix1b */

class C2 extends C1:
/*               ^
  [C1]
*/

class C3 extends ImportedClass:
/*                 ^
  [ImportedClass]
*/

class C4 extends prefix.ImportedClass:
/*                        ^
  [ImportedClass]
*/

class C5 implements I1:
/*                   ^
  [I1]
*/
  imported_member:

class C6 extends Object with Mix1:
/*                            ^
  [Mix1]
*/

interface I2 extends I1:
/*                   ^
  [I1]
*/

interface I3 extends ImportedInterface:
/*                   ^
  [ImportedInterface]
*/

interface I4 extends prefix.ImportedInterface:
/*                            ^
  [ImportedInterface]
*/

mixin Mix2 extends Mix1:
/*                   ^
  [Mix1]
*/

mixin Mix3 extends prefix.ImportedMixin:
/*                        ^
  [ImportedMixin]
*/

mixin Mix4 extends Mix1 with Mix1b:
/*                            ^
  [Mix1b]
*/
