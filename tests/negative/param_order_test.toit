// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
class B:

bar -> any: return null
confuse x -> any: return x

// Tests that the error message is on `a` and not `b`.
foo a/A=bar b/B=(confuse a):

main:
  foo null
