// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests whether the parser correctly handles multiline comments.

main:
  expect function1 == "correct"
  expect function2 == "correct"
  expect function3 == "correct"
  expect function4 == "correct"
  expect function5 == "correct"
  expect function6 == "correct"
  expect function7 == "correct"

function1/* Comment at end of function signature
  */:
  return "correct"

function2:
  return /* Between return and value*/"correct"

/*
/*x/ */
*/
function3: return "correct"

/*
/**/*
*/
function4:
  return "correct"

/*
/*\*/foo*/
/**\/bar*/
/*\\*/
*/
function5: return "correct"

/*
\/*foo
/\*bar
*/
function6: return "correct"

function7:
  /** Some nested comments
    ::::  // Some bad code that would trigger syntax errors if parsed.
    /* deeper
      ::::  // Some bad code that would trigger syntax errors if parsed.
      /* and deeper */  ::::  // Some bad code that would trigger syntax errors if parsed.
      ::::  // Some bad code that would trigger syntax errors if parsed.
      /* deep again, closing with trailing * */*
      ::::  // Some bad code that would trigger syntax errors if parsed.
    Make sure single line comments don't hide the closing comment // */
  */
  return "correct"
