// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test "test"

test param/string:
/*   @ def */
/*
      ^
  [def, usage]
*/
  print param
/*      @ usage */
/*
          ^
  [def, usage]
*/
