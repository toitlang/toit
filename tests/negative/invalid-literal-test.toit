// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  x := "\z";
  block := (: 499)
  "$block"
  "foo$(x)bar$block"
  c := '🇩🇰'
  list := [ block ]
  set := { block }
  map := { block : block }
  unresolved
