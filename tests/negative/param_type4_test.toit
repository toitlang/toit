// Copyright (C) 2020 Toitware ApS. All rights reserved.

interface Inter:

class A:

class B implements Inter:

foo str/Inter:
  return str

confuse x: return x

main:
  confuse A
  confuse B
  foo (confuse A)
