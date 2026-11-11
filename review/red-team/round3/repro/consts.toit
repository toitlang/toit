// Copyright (C) 2026 Toit contributors.
// Const structures to force instance / array / slice / map literals.
LIST  ::= [11, 22, 33, 44, 55, 66, 77, 88]
BA    ::= #[0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22]
STR   ::= "the-quick-brown-fox-string-literal"
MAP   ::= {"alpha": 1, "beta": 2, "gamma": 3}
SET   ::= {10, 20, 30, 40}
SLICE ::= STR[4..14]
BASLICE ::= BA[1..6]

main:
  print LIST
  print BA
  print STR
  print MAP
  print SET
  print SLICE
  print BASLICE
  print LIST[3]
  print MAP["beta"]
