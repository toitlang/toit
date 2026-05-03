// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Gadget:
/*    @ def */
  value := 0

helper x/Gadget:
/*       @ type-param */
  return x

make-gadget -> Gadget:
/*             @ type-return */
  return Gadget
/*       @ ctor-call */
