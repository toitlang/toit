// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
