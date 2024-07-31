// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .imported3
import .imported5 as pre

// bar and ExportedClass3 are imported with a prefix, so they should not be shown.
export ExportedClass
/*     ^~~~~~~~~~~~~
  + ExportedClass, ExportedClass2, foo
  - bar, ExportedClass3
*/
