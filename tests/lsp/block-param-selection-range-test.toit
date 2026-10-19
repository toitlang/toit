// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [b] [--named] -> none:
/*
@foo-start
     ^
     []
    [  ]
[foo-start body-end]
*/
/*
           ^
           [    ]
        [        ]
[foo-start body-end]
*/
  b.call
/*
        @body-end
*/
