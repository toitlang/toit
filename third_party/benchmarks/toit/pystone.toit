// Copyright (C) 2022 Toitware ApS.

// This is a Toit implementation of the Pystone benchmark from:
//
//    https://svn.python.org/projects/python/trunk/Lib/test/pystone.py
//
// The benchmark was originally implemented in ADA by Reinhold P. Weicker,
// translated to C by Rick Richardson, and then to Python by Guido van Rossum.

import .benchmark

LOOPS ::= 10_000

Ident1 ::= 1
Ident2 ::= 2
Ident3 ::= 3
Ident4 ::= 4
Ident5 ::= 5

class Record:
  PtrComp := null
  Discr := 0
  EnumComp := 0
  IntComp := 0
  StringComp := 0

  constructor:
  constructor .PtrComp .Discr .EnumComp .IntComp .StringComp:

  copy -> Record:
    return Record PtrComp Discr EnumComp IntComp StringComp

TRUE ::= true
FALSE ::= false

main:
  log_execution_time "Pystone" --iterations=10:
    pystones --loops=LOOPS

pystones --loops=LOOPS:
  return Proc0 loops

IntGlob := 0
BoolGlob := FALSE
Char1Glob := '\0'
Char2Glob := '\0'
Array1Glob := List 51: 0
Array2Glob := List 51: List 51: 0
PtrGlb := null
PtrGlbNext := null

Proc0 loops=LOOPS:
  PtrGlbNext = Record
  PtrGlb = Record
  PtrGlb.PtrComp = PtrGlbNext
  PtrGlb.Discr = Ident1
  PtrGlb.EnumComp = Ident3
  PtrGlb.IntComp = 40
  PtrGlb.StringComp = "DHRYSTONE PROGRAM, SOME STRING"
  String1Loc := "DHRYSTONE PROGRAM, 1'ST STRING"
  Array2Glob[8][7] = 10

  loops.repeat:
    Proc5
    Proc4
    IntLoc1 := 2
    IntLoc2 := 3
    IntLoc3 := null
    String2Loc := "DHRYSTONE PROGRAM, 2'ND STRING"
    EnumLoc := Ident2
    BoolGlob = not (Func2 String1Loc String2Loc)
    while IntLoc1 < IntLoc2:
      IntLoc3 = 5 * IntLoc1 - IntLoc2
      IntLoc3 = Proc7 IntLoc1 IntLoc2
      IntLoc1 = IntLoc1 + 1
    Proc8 Array1Glob Array2Glob IntLoc1 IntLoc3
    PtrGlb = Proc1 PtrGlb
    CharIndex := 'A'
    while CharIndex <= Char2Glob:
      if EnumLoc == (Func1 CharIndex 'C'):
        EnumLoc = Proc6 Ident1
      CharIndex = CharIndex + 1
    IntLoc3 = IntLoc2 * IntLoc1
    IntLoc2 = IntLoc3 / IntLoc1
    IntLoc2 = 7 * (IntLoc3 - IntLoc2) - IntLoc1
    IntLoc1 = Proc2 IntLoc1

Proc1 PtrParIn:
    NextRecord := PtrGlb.copy
    PtrParIn.PtrComp = NextRecord
    PtrParIn.IntComp = 5
    NextRecord.IntComp = PtrParIn.IntComp
    NextRecord.PtrComp = PtrParIn.PtrComp
    NextRecord.PtrComp = Proc3 NextRecord.PtrComp
    if NextRecord.Discr == Ident1:
      NextRecord.IntComp = 6
      NextRecord.EnumComp = Proc6 PtrParIn.EnumComp
      NextRecord.PtrComp = PtrGlb.PtrComp
      NextRecord.IntComp = Proc7 NextRecord.IntComp 10
    else:
      PtrParIn = NextRecord.copy
    NextRecord.PtrComp = null
    return PtrParIn

Proc2 IntParIO:
  IntLoc := IntParIO + 10
  while true:
    EnumLoc := null
    if Char1Glob == 'A':
      IntLoc = IntLoc - 1
      IntParIO = IntLoc - IntGlob
      EnumLoc = Ident1
    if EnumLoc == Ident1:
      break
  return IntParIO

Proc3 PtrParOut:
  if PtrGlb:
    PtrParOut = PtrGlb.PtrComp
  else:
    IntGlob = 100
  PtrGlb.IntComp = Proc7 10 IntGlob
  return PtrParOut

Proc4:
  BoolLoc := Char1Glob == 'A'
  BoolLoc = BoolLoc or BoolGlob
  Char2Glob = 'B'

Proc5:
  Char1Glob = 'A'
  BoolGlob = FALSE

Proc6 EnumParIn:
  EnumParOut := EnumParIn
  if not Func3 EnumParIn:
    EnumParOut = Ident4
  if EnumParIn == Ident1:
    EnumParOut = Ident1
  else if EnumParIn == Ident2:
    if IntGlob > 100:
      EnumParOut = Ident1
    else:
      EnumParOut = Ident4
  else if EnumParIn == Ident3:
    EnumParOut = Ident2
  else if EnumParIn == Ident4:
    // pass
  else if EnumParIn == Ident5:
    EnumParOut = Ident3
  return EnumParOut

Proc7 IntParI1 IntParI2:
  IntLoc := IntParI1 + 2
  IntParOut := IntParI2 + IntLoc
  return IntParOut

Proc8 Array1Par Array2Par IntParI1 IntParI2:
  IntLoc := IntParI1 + 5
  Array1Par[IntLoc] = IntParI2
  Array1Par[IntLoc+1] = Array1Par[IntLoc]
  Array1Par[IntLoc+30] = IntLoc
  2.repeat:
    Array2Par[IntLoc][IntLoc + it] = IntLoc
  Array2Par[IntLoc][IntLoc-1] = Array2Par[IntLoc][IntLoc-1] + 1
  Array2Par[IntLoc+20][IntLoc] = Array1Par[IntLoc]
  IntGlob = 5

Func1 CharPar1 CharPar2:
  CharLoc1 := CharPar1
  CharLoc2 := CharLoc1
  if CharLoc2 != CharPar2:
    return Ident1
  else:
    return Ident2

Func2 StrParI1 StrParI2:
  IntLoc := 1
  CharLoc := null
  while IntLoc <= 1:
    if (Func1 StrParI1[IntLoc] StrParI2[IntLoc+1]) == Ident1:
      CharLoc = 'A'
      IntLoc = IntLoc + 1
  if CharLoc >= 'W' and CharLoc <= 'Z':
    IntLoc = 7
  if CharLoc == 'X':
    return TRUE
  else:
    if StrParI1 > StrParI2:
      IntLoc = IntLoc + 7
      return TRUE
    else:
      return FALSE

Func3 EnumParIn:
  EnumLoc := EnumParIn
  if EnumLoc == Ident3: return TRUE
  return FALSE
