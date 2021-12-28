// Copyright (C) 2020 Toitware ApS. All rights reserved.

class B:
  // Tests that we don't try to print an invalid field name in an
  //   error message.
  := ?
  / int ::= ?

main:
  b := B
