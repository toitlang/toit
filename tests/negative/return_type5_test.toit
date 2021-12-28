// Copyright (C) 2020 Toitware ApS. All rights reserved.

interface Inter:

class A:

class B implements Inter:

confuse x: return x

foo -> Inter?:
  return confuse A

main:
  confuse A
  confuse B
  foo
