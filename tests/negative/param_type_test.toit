// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo str/string:
  return str

confuse x: return x

main:
  foo (confuse 499)
