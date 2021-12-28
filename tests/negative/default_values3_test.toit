// Copyright (C) 2019 Toitware ApS. All rights reserved.


main:
  foo
  foo null
  foo: 1

// The type of the default value and the parameter must agree.
foo [x]=(499):
  return x
