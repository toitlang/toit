// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo --bool_flag:

class A:
  constructor:
    // We run through the AST to see whether there is a return (making
    //   it a factory).
    // The traverse visitor was not checking correctly, if a value for
    //   the named argument was given.
    foo --bool_flag

main:
  a := A
