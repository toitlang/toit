// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x:
/*
@foo-start
^
[  ]
[foo-start body-end]
*/
  return x
/*
          @body-end
  ^
  [     ]
  [       ]
  [foo-start body-end]
*/
