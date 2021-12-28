// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
class B:

bar -> any: return null

would_throw -> any:
  unreachable

// Tests that the error message is on `a` and not `b`.
foo a/A=bar b/B=would_throw:

main:
  foo null
