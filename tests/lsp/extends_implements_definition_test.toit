// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
