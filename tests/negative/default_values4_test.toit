// Copyright (C) 2019 Toitware ApS. All rights reserved.

// No operators in default values.
foo x=5+3:
  return x

main:
  foo null
