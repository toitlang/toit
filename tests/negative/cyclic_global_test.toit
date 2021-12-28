// Copyright (C) 2020 Toitware ApS. All rights reserved.

global := foo
foo: return global

bar x:

main:
  // Accessing `global` leads to an exception complaining that the variable
  // is being initialized.
  bar global
