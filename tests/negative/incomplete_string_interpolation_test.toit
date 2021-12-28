// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  print "$( /* " // */
  // The next 'unresolved' doesn't give an error.
  // It's consumed while searching for the closing ')'.
  unresolved

  // With the `unresolved2` the string reports a missing closing '"'.
  unresolved2  // Gives an error.

  print """$( /* """ // */
  """  // Skipped over while searching for the closing ')', including
       // its closing delimiter in the next line.
  """  // This one is skipped over as ending delimiter of the bad token above.
  """  // This one is finally found.

  // At this point the string above is closed without error.
  unresolved3  // Gives an error.

  print """$(4     // Gives an error about not being allowed to call an expression.
    unresolved4  // Gives an error.
  // The following parenthesis isn't found, because it is too far to the left. However, the closing '"""' is then found.
 )"""

bar: bar 3  // This line is again active.
