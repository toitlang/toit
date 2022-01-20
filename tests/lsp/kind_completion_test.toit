// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .kind_completion_test as prefix
/*      ^
  + kind_completion_test#Module
*/

class SomeClass:
  member param:
    member param
/*  ^~~~~~~~~~~~
  + member#Method, param#Variable
*/
  static fun:
  static static_field := 499
  static CONSTANT ::= 42

class SomeClass2 extends SomeClass:
/*                       ^~~~~~~~~
  + SomeClass#Class
*/

  constructor:
  constructor.named:
  constructor.factory: return SomeClass2

interface I:

class I_Impl implements I:
/*                      ^
  + I#Interface
*/

global := 499
CONSTANT ::= 42
CONSTANT_OTHER ::= 7
__ ::= 11  // Should not be a constant.

toplevel_fun x: return x

main:
  local := 42
  local
/*^~~~~
  + SomeClass#Class, SomeClass2#Class, main#Function
  + global#Variable, CONSTANT#Constant, CONSTANT_OTHER#Constant
  + toplevel_fun#Function, true#Keyword, I#Interface
  + prefix#Module
  + local#Variable
  + __#Variable
*/

  SomeClass.fun
/*          ^~~
  + fun#Function, static_field#Variable, CONSTANT#Constant
*/

  SomeClass2.factory
/*           ^~~~~~~
  + named#Constructor, factory#Constructor
*/
