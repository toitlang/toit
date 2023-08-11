// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// This file has trailing whitespace and thus must be edited with
//   care, as many editors will automatically remove the whitespace.
main:
  // Following line has trailing spaces.
  expect-equals "" """     
       """

  // Following line has trailing spaces.
  expect-equals "" """     
       $("")"""

  // Following line has a trailing tab.
  expect-equals "\t\n  " """	
  """

  // 4 spaces followed by 2 spaces.
  expect-equals "\n\n" """
    
  
    """

  // 2 spaces followed by 4 spaces.
  expect-equals "\n\n" """
  
    
    """
