// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..tests.syntax-companion
import .syntax-companion show show-foo2
import io

import ..tests.syntax-companion show global-x global-y
import .syntax-companion show global-x global-y
import io show Buffer

import ..tests.syntax-companion show
  global-x
  global-y
import .syntax-companion
  show
    global-x
    global-y
import
  io
  show
  Buffer
  InMixin

import ..tests.syntax-companion show *
import .syntax-companion show *
import bytes show *

import ..tests.syntax-companion as imp1
import .syntax-companion as imp2
import bytes as imp3

import core as core

export global-x
export global-x global-y
export *

import .syntax-companion as as-prefix

import-foo:
show-foo:

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

global := some-fun 499 "str" true
global2 /any := some-fun 499 "str" true
global3 /Type := some-fun 499 "str" true

globalb /*comment*/ := some-fun 499 "str" true
global2b /any/*comment*/ := some-fun 499 "str" true
global3b /Type/*comment*/ := some-fun 499 "str" true

globalc /*comment*/ ::= some-fun 499 "str" true
global2c /any/*comment*/ ::= some-fun 499 "str" true
global3c /**/ /Type/*comment*/ ::= some-fun 499 "str" true

global-fun:
  while true: some-fun "2" /*comment*/ null true

global-fun2:
  while true: some-fun "2" /*comment*/ null true

global-fun2b: while true: some-fun "2" /*comment*/ null true

global-fun3 x:
  while true: some-fun "2" /*comment*/ null true

global-fun4 x/any y/Type:
  while true: some-fun "2" /*comment*/ null true

global-fun5 x/any y/ Type?:
  while true: some-fun "2" /*comment*/ null true

global-fun6 x / any y/Type?: while true: some-fun "2" /*comment*/ null true

global-fun7 -> none:
  while true: some-fun "2" /*comment*/ null true

global-fun8 x/io.Buffer -> none:
  while true: some-fun "2" /*comment*/ null true

global-fun9 -> none
    x / io.Buffer?
    y/any:
  while true: some-fun "2" /*comment*/ null true

global-fun9b -> none
    x /io.Buffer? /*comment*/
    y /any:
  while true: some-fun "2" /*comment*/ null true

some-fun x: return null
some-fun x y: return null
some-fun x y z: return null

foo: return null

default-values x=499 y="some_str" z=(while true: 499) g=x.bar h=foo[499] i=foo.call:

default-values2 x=499
    y="some_str"
    z=(while true: 499)
    g=x.bar
    h=foo[499]
    i=foo.call:

default-values3 --x=499 --y="some_str" --z=(while true: 499) --g=x.bar --h=foo[499] --i=foo.call:
  default-values4 --i=33

default-values4
    --x=499
    --y="some_str"
    --z=(while true: 499)
    --g=x.bar
    --h=foo[499]
    --i=foo.call:

global-setter= x:
  499
global-setter2= x -> none:
  42

fun
    --some
    --args
    on
    multiple
    lines
:
  print "with colon at same level as 'fun'"

class X-Of:

abstract class Type:
  foo := 499
  constructor:

  operator == other:
    return true
  operator + other:
    return 499
  operator >> shift-amount:
    return 42
  operator << shift-amount:
    return 0
  operator >>> shift-amount:
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

  instance-setter= x: 42
  instance-setter2= y -> none: 499

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

SOME-CONSTANT ::= 499
CONSTANT499 ::= 42

import-fun: return 42
export-fun: return 42
class-fun: return 499
interface-fun: return 9
monitor-fun: return 4
is-something-fun:
  is-local := 42

g-str / string? ::= null
g-iii / int?  ::= null
g-boo / bool? ::= null
g-flo / float? ::= null
g-str2 / string ::= "str"
g-iii2 / int  ::= 499
g-boo2 / bool ::= true
g-flo2 / float ::= 3.14

fun1 str/string? iii/int? boo/bool? flo/float?:
fun2 str/string iii/int boo/bool flo/float:

class Cll:
  fun1 str/string? iii/int? boo/bool? flo/float?:
  fun2 str/string iii/int boo/bool flo/float:
  fun3 x / Cll:

  field := ?
  constructor:
    field = 499

  static SOME-STATIC-CONSTANT ::= 42
  static STATIC-CONSTANT499 ::= 3

fun:
  unreachable

fun2 unreachable:

run [block]: block.call

labeled-continue:
  run:
    continue.run

class A:
class A1:
class AbC0:

fun-with-bracket-in-default default=SOME-LIST[0][1][2]:

fun-with-default-block default=A [block]:

SOME-LIST ::= [1, 2]
fun-with-default-bracket arg1 default=SOME-LIST[arg1]:

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
  """c"""
  // Empty triple-quoted string.
  """"""
  // Some examples with quotes at the start or end of a triple-quoted string.
  """""""
  """"""""
  """c"""
  """"c""""
  """""c"""""
  """$c"""
  """"$c""""
  """""$c"""""
  """$c """
  """"$c """"
  """""$c """""
  some-fun """"" $c """"" ""

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

  cc := CONSTANT499 + SOME-CONSTANT
  cc2 := Cll.SOME-STATIC-CONSTANT + Cll.STATIC-CONSTANT499

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

  assert-x := 499
  assert-x--
  as-something := assert-x + 42
  null-foo := as-something + assert-x
  assert-x += null-foo

  x-of := X-Of
