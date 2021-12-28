// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .non_existing show A

class B:
  foo:

main:
  b := B
  b.bar  // Bad.
