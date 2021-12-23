// Copyright (C) 2019 Toitware ApS. All rights reserved.

interface A implements B:

interface B implements A:

class C implements A:

main:
  c := C
