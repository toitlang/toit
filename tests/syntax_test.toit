// Copyright (C) 2019 Toitware ApS. All rights reserved.

import ..tests.syntax
import .syntax
import bytes

import ..tests.syntax show global_x global_y
import .syntax show global_x global_y
import bytes show Buffer

import ..tests.syntax show
  global_x
  global_y
import .syntax
  show
    global_x
    global_y
import
  bytes
  show
  Buffer
  BufferConsumer

import ..tests.syntax show *
import .syntax show *
import bytes show *

import ..tests.syntax as imp1
import .syntax as imp2
import bytes as imp3

import core as core

export global_x
export global_x global_y
export *

// Normal comment
/* Normal multiline // with normal
/* nested multiline */
foo bar
```
Markdown comment (doesn't need to be colored).
```
Links: http://www.example.com
*/

separator := null  // To show the separations.

/// Doc-style comment
separator2 := null  // To show the separations.
/// Doc-style with // normal comment
separator3 := null  // To show the separations.
/**
doc-style
/* with nested comment */
```
Markdown comment
```
[References]

/**
Nested multi doc.
*/
Markdown `code`.

Links: http://www.example.com
*/
separator4 := null  // To show the separations.

global := some_fun 499 "str" true
global2 /any := some_fun 499 "str" true
global3 /Type := some_fun 499 "str" true

globalb /*comment*/ := some_fun 499 "str" true
global2b /any/*comment*/ := some_fun 499 "str" true
global3b /Type/*comment*/ := some_fun 499 "str" true

globalc /*comment*/ ::= some_fun 499 "str" true
global2c /any/*comment*/ ::= some_fun 499 "str" true
global3c /**/ /Type/*comment*/ ::= some_fun 499 "str" true

global_fun:
  while true: some_fun "2" /*comment*/ null true

global_fun2:
  while true: some_fun "2" /*comment*/ null true

global_fun2b: while true: some_fun "2" /*comment*/ null true

global_fun3 x:
  while true: some_fun "2" /*comment*/ null true

global_fun4 x/any y/Type:
  while true: some_fun "2" /*comment*/ null true

global_fun5 x/any y/ Type?:
  while true: some_fun "2" /*comment*/ null true

global_fun6 x / any y/Type?: while true: some_fun "2" /*comment*/ null true

global_fun7 -> none:
  while true: some_fun "2" /*comment*/ null true

global_fun8 x/bytes.Buffer -> none:
  while true: some_fun "2" /*comment*/ null true

global_fun9 -> none
    x / bytes.Buffer?
    y/any:
  while true: some_fun "2" /*comment*/ null true

global_fun9b -> none
    x /bytes.Buffer? /*comment*/
    y /any:
  while true: some_fun "2" /*comment*/ null true

some_fun x: return null
some_fun x y: return null
some_fun x y z: return null

foo: return null

default_values x=499 y="some_str" z=(while true: 499) g=x.bar h=foo[499] i=foo.call:

default_values2 x=499
    y="some_str"
    z=(while true: 499)
    g=x.bar
    h=foo[499]
    i=foo.call:

default_values3 --x=499 --y="some_str" --z=(while true: 499) --g=x.bar --h=foo[499] --i=foo.call:
  default_values4 --i=33

default_values4
    --x=499
    --y="some_str"
    --z=(while true: 499)
    --g=x.bar
    --h=foo[499]
    --i=foo.call:

global_setter= x:
  499
global_setter2= x -> none:
  42

abstract class Type:
  foo := 499
  constructor:

  operator == other:
    return true
  operator + other:
    return 499
  operator >> shift_amount:
    return 42
  operator << shift_amount:
    return 0
  operator >>> shift_amount:
    return 42

  operator < other: return true
  operator > other: return true
  operator <= other: return true
  operator >= other: return true
  operator - other: return 0
  operator * other: return 0
  operator / other: return 3
  operator % other: return 22
  operator ^ other: return 0
  operator & other: return 0
  operator | other: return 4
  operator [] i:
  operator []= i val:
  operator [..] --from --to:

  method x/Type? -> none:
    print x
  other --flag --named:
    other --no-flag --named=33

  abstract gee x y
  static foobar x y: return 1 + 2
  abstract/**/ foo x y
  static /*comment*/bar y: return 0x499

  instance_setter= x: 42
  instance_setter2= y -> none: 499

class Type3 extends Type:
  foo x y: return x + y
  gee x y:

class Type2:
  method2:
    (Type3).method null
    print 3

interface I1:
  m1

interface I2 extends I1 implements I3:
  m2
  m3

interface I3:
  m3

class ClassConstructor:
  field := null
  constructor:
  constructor x/string:
  constructor .field y/int:
  constructor.named:
  constructor.named .field y/int:
  constructor.named arg/int:

constant1 ::= 1234_5678
constant1b ::= 1_2_3_4_5_6_7_8
constant1c ::= -1234_5678
constant2 ::= -123_456.789_123
constant2b ::= -1_2_3_4_5_6.7_8_9_1_2_3
constant2c ::= -.123_456
constant2d ::= .123_456
constant2e ::= .1_2_3_4_5_6
constant2f ::= 123_456.0
constant3 ::= 0xFFFF_FFFF + 0X1234_22
constant3b ::= 0xF_F_F_F_F_F_F_F + 0X1_2_3_4_2_2
constant4 ::= 0b0101_0101 + 0B1101_1010 + constant3b
constant4b ::= 0b0_1_0_1_0_1_0_1 + 0B1101_1010 + constant4
constant5 ::= 1.5e17 + -.7e+3 + 1e-10
constant5b ::= 1_0.5_3e1_7 + -.7_3e+3_2 + 0_1e-1_0
constant6 ::= 0xa.bP-3 + -0X7107p44 + 0x.abcp-77
constant6b ::= 0xa_b_c.b_cP-3_3 + -0X7_1_0_7p4_4 + 0x.a_b_cp-7_7

SOME_CONSTANT ::= 499
CONSTANT499 ::= 42

import_fun: return 42
export_fun: return 42
class_fun: return 499
interface_fun: return 9
monitor_fun: return 4
is_something_fun:
  is_local := 42

g_str / string? ::= null
g_iii / int?  ::= null
g_boo / bool? ::= null
g_flo / float? ::= null
g_str2 / string ::= "str"
g_iii2 / int  ::= 499
g_boo2 / bool ::= true
g_flo2 / float ::= 3.14

fun1 str/string? iii/int? boo/bool? flo/float?:
fun2 str/string iii/int boo/bool flo/float:

class Cll:
  fun1 str/string? iii/int? boo/bool? flo/float?:
  fun2 str/string iii/int boo/bool flo/float:
  fun3 x / Cll:

  field := ?
  constructor:
    field = 499

  static SOME_STATIC_CONSTANT ::= 42
  static STATIC_CONSTANT499 ::= 3

fun:
  unreachable

fun2 unreachable:

run [block]: block.call

labeled_continue:
  run:
    continue.run

class A:
class A1:
class AbC0:

fun_with_bracket_in_default default=SOME_LIST[0][1][2]:

fun_with_default_block default=A [block]:

SOME_LIST ::= [1, 2]
fun_with_default_bracket arg1 default=SOME_LIST[arg1]:

class Slice:
  operator [..] --from=0 --to=0:

main:
  5 is any
  "str" is not float
  "str" as string
  5.9 as float
  5 as int
  true is bool
  print false as bool
  local := 2
  local >>= 499
  local >>>= 2

  for ;;: break
  for x := 0;;: break
  for x := 0;;x++: break
  1 + 2
  1 - 2
  0 * 3
  5 / 2
  3 % 1
  5 << 1
  5 >> 2
  8 >>> 3
  5 < 3
  9 > 3
  5 <= 3
  8 >= 5
  3 | 5
  3 & 2
  3 ^ 3
  ~5
  y := 0
  y += 0
  y -= 0
  y *= 0
  y /= 3
  y %= 9
  y <<= 3
  y >>= 5
  y >>>= 3
  y |= 9
  y &= 2
  y ^= 9
  y = ~y

  c := '\''
  c = '\\'
  c = '\x12'
  c = '\u1f3A'
  str := "\""
  mstr := """x"""
  istr := """$("""
  """)"""

  local2 := ?
  local3 := true ? false : null

  local4 /int := 499
  local5 /string? := ""
  local6/**/ /int := 499
  local7/**/ /string? := ""
  local8 /core.List? ::= []

  while true:
    if local4 == 0: continue
    break

  cc := CONSTANT499 + SOME_CONSTANT
  cc2 := Cll.SOME_STATIC_CONSTANT + Cll.STATIC_CONSTANT499

  a0 / A := A
  a0_ / A? := null
  a1 / A1 := A1
  a1_ / A1? := null
  a2 / AbC0 := AbC0
  a2_ / AbC0? := null

  bytes := #[1, 2, 3]

  (Slice)[1..2]
  (Slice)[..2]
  (Slice)[1..]
  (Slice)[..]

  "string with\\ \" escapes"
