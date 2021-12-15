// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

// This file has trailing whitespace and thus must be edited with
//   care, as many editors will automatically remove the whitespace.
main:
  // Following line has trailing spaces.
  expect_equals "" """     
       """

  // Following line has trailing spaces.
  expect_equals "" """     
       $("")"""

  // Following line has a trailing tab.
  expect_equals "\t\n  " """	
  """

  // 4 spaces followed by 2 spaces.
  expect_equals "\n\n" """
    
  
    """

  // 2 spaces followed by 4 spaces.
  expect_equals "\n\n" """
  
    
    """
