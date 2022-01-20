// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition_imported
import .definition_imported as prefix

class C1:
/*    @ C1 */

interface I1:
/*        @ I1 */

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
