// Copyright (C) 2019 Toitware ApS. All rights reserved.

// The type of the default value and the parameter must agree.
foo x=(:499):
  return x.call

main:
  foo null
