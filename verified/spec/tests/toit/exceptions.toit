// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class MyError:
  code/int
  constructor .code:
  stringify: return "MyError($code)"

thrower x:
  if x == 0: throw "zero"
  if x == 1: throw (MyError 7)
  if x == 2: return [1, 2, 3][5]  // Out of bounds.
  if x == 3: return (null as any).foo  // Lookup failure.
  if x == 4: return 1 / 0
  if x == 5: return (x as any) as string  // As-check failure.
  return x

class A:
  foo: return "A.foo"

main:
  6.repeat:
    e := catch: thrower it
    print "$it: $e"
  print (catch: thrower 9)
  // Rethrow from a nested catch.
  e := catch:
    catch --unwind=(: it == "pass"):
      throw "pass"
  print "outer caught $e"
  // Exceptions through blocks and lambdas.
  e2 := catch:
    [1, 2, 3].do:
      if it == 2: throw "from block $it"
  print e2
  lambda := :: throw "from lambda"
  print (catch: lambda.call)
  // catch with --trace=false returning value.
  v := catch: 42
  print v
  // Typed exceptions carry fields.
  e3 := catch: throw (MyError 99)
  print (e3 as MyError).code
  // Calling a method that doesn't exist on a value.
  print (catch: (A as any).bar)
  print (catch: ([] as any).foo 1 2)
  print (catch: ("x" as any) + 1)
