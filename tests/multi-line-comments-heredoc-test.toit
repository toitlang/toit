// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests whether the parser correctly handles heredoc multiline comments.

main:
  expect test1 == "correct"
  expect test2 == "correct"
  expect test3 == "correct"

/** << with spaces
*/ closing ignored.
with spaces */
test1:
  /* << heredoc
  */ closing ignored.
  heredoc */
  return "correct"

/**<<with spaces
*/ closing ignored.
with spaces*/
test2:
  /*<<heredoc
  */ closing ignored.
  heredoc*/
  return "correct"

/** << with spaces
*/ closing ignored.
with spaces*/
test3:
  /* << heredoc
  /* nested ignored
  heredoc*/
  return "correct"
