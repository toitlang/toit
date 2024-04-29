// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .kind-completion-test as prefix
/*      ^
  + kind-completion-test#Module
*/

class SomeClass:
  member param:
    member param
/*  ^~~~~~~~~~~~
  + member#Method, param#Variable
*/
  static fun:
  static static-field := 499
  static CONSTANT ::= 42

class SomeClass2 extends SomeClass:
/*                       ^~~~~~~~~
  + SomeClass#Class
*/

  constructor:
  constructor.named:
  constructor.factory: return SomeClass2

interface I:

class I-Impl implements I:
/*                      ^
  + I#Interface
*/

mixin Mix:

class Mix_Impl extends Object with Mix:
/*                                 ^~~
  + Mix#Class
*/

global := 499
CONSTANT ::= 42
CONSTANT-OTHER ::= 7
__ ::= 11  // Should not be a constant.

toplevel-fun x: return x

main:
  local := 42
  local
/*^~~~~
  + SomeClass#Class, SomeClass2#Class, main#Function
  + global#Variable, CONSTANT#Constant, CONSTANT-OTHER#Constant
  + toplevel-fun#Function, true#Keyword, I#Interface, Mix#Class
  + prefix#Module
  + local#Variable
  + __#Variable
*/

  SomeClass.fun
/*          ^~~
  + fun#Function, static-field#Variable, CONSTANT#Constant
*/

  SomeClass2.factory
/*           ^~~~~~~
  + named#Constructor, factory#Constructor
*/
