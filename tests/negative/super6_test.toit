// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  :  // No name for method.
    // No error on super call since we already reported an error on the method name.
    super unresolved
    super = unresolved
