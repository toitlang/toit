// Copyright (C) 2019 Toitware ApS. All rights reserved.

// The type of the default value and the parameter must agree.
foo [x]=(499):
  return x

main:
  foo
  foo null
  foo: 1

