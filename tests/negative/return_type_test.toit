// Copyright (C) 2020 Toitware ApS. All rights reserved.

confuse x: return x

foo -> string:
  return confuse 499

main:
  foo
