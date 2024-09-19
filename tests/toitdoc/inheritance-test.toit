// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import expect show *

import .inheritance

import ...tools.toitdoc.lsp-exports as lsp
import ...tools.toitdoc.src.inheritance as inheritance

main:
  no-shadow-different-name
  no-shadow-different-name-deep
  no-shadow-same-name
  full-override
  partial-override
  partial-override-multiple
  partial-override-twice
  named
  named2
  named-skipping-optional
  mixins-simple
  mixins-multiple
  mixins-extended
  overridden
  mixins-extended-deep
  mixins-many

no-shadow-different-name:
  summaries := create-summaries """
    class A:
      foo:

    class B extends A:
      bar:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  foo/inheritance.InheritedMember := inherited-B[0]
  expect-equals "foo" foo.member.name
  expect foo.member.is-method
  expect-equals class-A.methods[0] foo.member.target
  expect-equals 0 foo.partially-shadowed-by.size
  expect-equals 0 result.shadowing.size

no-shadow-different-name-deep:
  summaries := create-summaries """
    class A:
      foo:

    class B extends A:
    class C extends B:
    class D extends C:
    class E extends D:

    class F extends E:
      bar:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  class-C/lsp.Class := classes[2]
  class-D/lsp.Class := classes[3]
  class-E/lsp.Class := classes[4]
  class-F/lsp.Class := classes[5]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  expect-equals "C" class-C.name
  expect-equals "D" class-D.name
  expect-equals "E" class-E.name
  expect-equals "F" class-F.name
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  inherited-C/List := result.inherited[class-C]
  inherited-D/List := result.inherited[class-D]
  inherited-E/List := result.inherited[class-E]
  inherited-F/List := result.inherited[class-F]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  expect-equals 1 inherited-C.size
  expect-equals 1 inherited-D.size
  expect-equals 1 inherited-E.size
  expect-equals 1 inherited-F.size
  [inherited-B, inherited-C, inherited-D, inherited-E, inherited-F].do: | inherited/List |
    foo/inheritance.InheritedMember := inherited[0]
    expect-equals "foo" foo.member.name
    expect foo.member.is-method
    expect-equals class-A.methods[0] foo.member.target
    expect-equals 0 foo.partially-shadowed-by.size
  expect-equals 0 result.shadowing.size

no-shadow-same-name:
  summaries := create-summaries """
    class A:
      foo:

    class B extends A:
      foo x:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  foo/inheritance.InheritedMember := inherited-B[0]
  expect-equals "foo" foo.member.name
  expect foo.member.is-method
  expect-equals class-A.methods[0] foo.member.target
  expect-equals 0 foo.partially-shadowed-by.size
  expect-equals 0 result.shadowing.size

full-override:
  summaries := create-summaries """
    class A:
      foo x:

    class B extends A:
      foo x:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  expect-equals 0 inherited-A.size
  expect-equals 0 inherited-B.size
  foo-A/lsp.ClassMember := class-A.methods[0]
  foo-B/lsp.ClassMember := class-B.methods[0]
  overriding-foo-A := result.shadowing.get (inheritance.ShadowKey class-A foo-A)
  key2 := inheritance.ShadowKey class-B foo-B
  overriding-foo-B := result.shadowing[key2]
  expect-null overriding-foo-A
  expect-equals 1 overriding-foo-B.size

  expect-equals overriding-foo-B[0] foo-A

partial-override:
  summaries := create-summaries """
    class A:
      foo x y=:

    class B extends A:
      foo x:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  foo-A/lsp.Method := class-A.methods[0]
  foo-B/lsp.Method := class-B.methods[0]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  foo/inheritance.InheritedMember := inherited-B[0]
  expect-equals foo-A foo.member.target
  overriding-foo-A/List? := result.shadowing.get (inheritance.ShadowKey class-A foo-A)
  overriding-foo-B/List? := result.shadowing.get (inheritance.ShadowKey class-B foo-B)
  expect-null overriding-foo-A
  expect-equals 1 overriding-foo-B.size
  expect-equals foo-A overriding-foo-B[0]

partial-override-multiple:
  summaries := create-summaries """
    class A:
      foo x y=:

    class B extends A:
      foo x:

    class C extends B:
      foo x:

    class D extends C:
      foo x:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  class-C/lsp.Class := classes[2]
  class-D/lsp.Class := classes[3]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  expect-equals "C" class-C.name
  expect-equals "D" class-D.name
  foo-A/lsp.Method := class-A.methods[0]
  foo-B/lsp.Method := class-B.methods[0]
  foo-C/lsp.Method := class-C.methods[0]
  foo-D/lsp.Method := class-D.methods[0]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  inherited-C/List := result.inherited[class-C]
  inherited-D/List := result.inherited[class-D]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  expect-equals 1 inherited-C.size
  expect-equals 1 inherited-D.size
  inherited-foo-b/inheritance.InheritedMember := inherited-B[0]
  inherited-foo-c/inheritance.InheritedMember := inherited-C[0]
  inherited-foo-d/inheritance.InheritedMember := inherited-D[0]
  expect-equals foo-A inherited-foo-b.member.target
  expect-equals foo-A inherited-foo-c.member.target
  expect-equals foo-A inherited-foo-d.member.target
  overriding-foo-A/List? := result.shadowing.get (inheritance.ShadowKey class-A foo-A)
  overriding-foo-B/List? := result.shadowing.get (inheritance.ShadowKey class-B foo-B)
  overriding-foo-C/List? := result.shadowing.get (inheritance.ShadowKey class-C foo-C)
  overriding-foo-D/List? := result.shadowing.get (inheritance.ShadowKey class-D foo-D)
  expect-null overriding-foo-A
  expect-equals 1 overriding-foo-B.size
  expect-equals foo-A overriding-foo-B[0]
  expect-equals 2 overriding-foo-C.size
  expect (overriding-foo-C.contains foo-A)
  expect (overriding-foo-C.contains foo-B)
  expect-equals 2 overriding-foo-D.size
  expect (overriding-foo-D.contains foo-A)
  expect (overriding-foo-D.contains foo-C)

partial-override-twice:
  summaries := create-summaries """
    class A:
      foo x y=:

    class B extends A:
      foo x --named=:

    class C extends B:
      foo x:

    class D extends C:
      foo x y= --named=:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  class-C/lsp.Class := classes[2]
  class-D/lsp.Class := classes[3]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  expect-equals "C" class-C.name
  expect-equals "D" class-D.name
  foo-A/lsp.Method := class-A.methods[0]
  foo-B/lsp.Method := class-B.methods[0]
  foo-C/lsp.Method := class-C.methods[0]
  foo-D/lsp.Method := class-D.methods[0]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  inherited-C/List := result.inherited[class-C]
  inherited-D/List := result.inherited[class-D]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  expect-equals 2 inherited-C.size
  expect-equals 0 inherited-D.size
  inherited-foo-b/inheritance.InheritedMember := inherited-B[0]
  inherited-foo-c1/inheritance.InheritedMember := inherited-C[0]
  inherited-foo-c2/inheritance.InheritedMember := inherited-C[1]
  expect-equals foo-A inherited-foo-b.member.target
  expect ({foo-A, foo-B}.contains inherited-foo-c1.member.target)
  expect ({foo-A, foo-B}.contains inherited-foo-c2.member.target)
  overriding-foo-A/List? := result.shadowing.get (inheritance.ShadowKey class-A foo-A)
  overriding-foo-B/List? := result.shadowing.get (inheritance.ShadowKey class-B foo-B)
  overriding-foo-C/List? := result.shadowing.get (inheritance.ShadowKey class-C foo-C)
  overriding-foo-D/List? := result.shadowing.get (inheritance.ShadowKey class-D foo-D)
  expect-null overriding-foo-A
  expect-equals 1 overriding-foo-B.size
  expect-equals foo-A overriding-foo-B[0]
  expect-equals 2 overriding-foo-C.size
  expect (overriding-foo-C.contains foo-A)
  expect (overriding-foo-C.contains foo-B)
  expect-equals 3 overriding-foo-D.size
  expect (overriding-foo-D.contains foo-A)
  expect (overriding-foo-D.contains foo-B)
  expect (overriding-foo-D.contains foo-C)

named:
  summaries := create-summaries """
    class A:
      foo --a= --b= --c=:

    class B extends A:
      foo --a --b --c:
      foo --a --b:
      foo --a --c:
      foo --a:
      foo --b --c:
      foo --b:
      foo --c:

    class C extends B:
      foo:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  class-C/lsp.Class := classes[2]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  expect-equals "C" class-C.name
  foo-A/lsp.Method := class-A.methods[0]
  foo-Bs/List := class-B.methods
  foo-C/lsp.Method := class-C.methods[0]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  inherited-C/List := result.inherited[class-C]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  expect-equals 7 inherited-C.size
  inherited-foo-b/inheritance.InheritedMember := inherited-B[0]
  expect-equals foo-A inherited-foo-b.member.target
  inherited-C.do: | inherited/inheritance.InheritedMember |
    expect (foo-Bs.contains inherited.member.target)

  overriding-foo-A/List? := result.shadowing.get (inheritance.ShadowKey class-A foo-A)
  expect-null overriding-foo-A

  foo-Bs.do: | foo-B/lsp.Method |
    overriding-foo-B/List? := result.shadowing.get (inheritance.ShadowKey class-B foo-B)
    expect-equals 1 overriding-foo-B.size
    expect-equals foo-A overriding-foo-B[0]

  overriding-foo-C/List? := result.shadowing.get (inheritance.ShadowKey class-C foo-C)
  expect-equals 1 overriding-foo-C.size
  expect-equals foo-A overriding-foo-C[0]

named2:
  summaries := create-summaries """
    class A:
      foo opt= --a= --b= --c=:

    class B extends A:
      foo --a --b --c:
      foo --a --b:
      foo --a --c:
      foo --a:
      foo --b --c:
      foo --b:
      foo --c:

    class C extends B:
      foo:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  class-C/lsp.Class := classes[2]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  expect-equals "C" class-C.name
  foo-A/lsp.Method := class-A.methods[0]
  foo-Bs/List := class-B.methods
  foo-C/lsp.Method := class-C.methods[0]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  inherited-C/List := result.inherited[class-C]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  expect-equals 8 inherited-C.size
  inherited-foo-b/inheritance.InheritedMember := inherited-B[0]
  expect-equals foo-A inherited-foo-b.member.target
  inherited-C.do: | inherited/inheritance.InheritedMember |
    expect ((foo-Bs.contains inherited.member.target) or foo-A == inherited.member.target)

  overriding-foo-A/List? := result.shadowing.get (inheritance.ShadowKey class-A foo-A)
  expect-null overriding-foo-A

  foo-Bs.do: | foo-B/lsp.Method |
    overriding-foo-B/List? := result.shadowing.get (inheritance.ShadowKey class-B foo-B)
    expect-equals 1 overriding-foo-B.size
    expect-equals foo-A overriding-foo-B[0]

  overriding-foo-C/List? := result.shadowing.get (inheritance.ShadowKey class-C foo-C)
  expect-equals 1 overriding-foo-C.size
  expect-equals foo-A overriding-foo-C[0]

named-skipping-optional:
  summaries := create-summaries """
    class A:
      foo --a --b= --z:

    class B extends A:
      foo --a --x= --y= --z:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  foo-A/lsp.Method := class-A.methods[0]
  foo-B/lsp.Method := class-B.methods[0]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  expect-equals 0 inherited-A.size
  expect-equals 1 inherited-B.size
  inherited-foo-b/inheritance.InheritedMember := inherited-B[0]
  expect-equals foo-A inherited-foo-b.member.target
  overriding-foo-A/List? := result.shadowing.get (inheritance.ShadowKey class-A foo-A)
  overriding-foo-B/List? := result.shadowing.get (inheritance.ShadowKey class-B foo-B)
  expect-null overriding-foo-A
  expect-equals 1 overriding-foo-B.size
  expect-equals foo-A overriding-foo-B[0]

mixins-simple:
  summaries := create-summaries """
    mixin M1:
      foo:

    class B:

    class A extends B with M1:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-M1/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  class-A/lsp.Class := classes[2]
  expect-equals "M1" class-M1.name
  expect-equals "B" class-B.name
  expect-equals "A" class-A.name
  inherited-M1/List := result.inherited[class-M1]
  inherited-B/List := result.inherited[class-B]
  inherited-A/List := result.inherited[class-A]
  expect-equals 0 inherited-M1.size
  expect-equals 0 inherited-B.size
  expect-equals 1 inherited-A.size
  foo/inheritance.InheritedMember := inherited-A[0]
  expect-equals "foo" foo.member.name
  expect foo.member.is-method

mixins-multiple:
  summaries := create-summaries """
    mixin M1:
      foo:

    mixin M2:
      bar:

    class B:

    class A extends B with M1 M2:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-M1/lsp.Class := classes[0]
  class-M2/lsp.Class := classes[1]
  class-B/lsp.Class := classes[2]
  class-A/lsp.Class := classes[3]
  expect-equals "M1" class-M1.name
  expect-equals "M2" class-M2.name
  expect-equals "B" class-B.name
  expect-equals "A" class-A.name
  inherited-M1/List := result.inherited[class-M1]
  inherited-M2/List := result.inherited[class-M2]
  inherited-B/List := result.inherited[class-B]
  inherited-A/List := result.inherited[class-A]
  expect-equals 0 inherited-M1.size
  expect-equals 0 inherited-M2.size
  expect-equals 0 inherited-B.size
  expect-equals 2 inherited-A.size
  // Note: the order of the inherited members isn't guaranteed.
  foo/inheritance.InheritedMember := inherited-A[0]
  expect-equals "foo" foo.member.name
  expect foo.member.is-method
  bar/inheritance.InheritedMember := inherited-A[1]
  expect-equals "bar" bar.member.name
  expect bar.member.is-method

mixins-extended:
  summaries := create-summaries """
    mixin M1:
      foo:

    mixin M2 extends M1:
      bar:

    class B:

    class A extends B with M2:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-M1/lsp.Class := classes[0]
  class-M2/lsp.Class := classes[1]
  class-B/lsp.Class := classes[2]
  class-A/lsp.Class := classes[3]
  expect-equals "M1" class-M1.name
  expect-equals "M2" class-M2.name
  expect-equals "B" class-B.name
  expect-equals "A" class-A.name
  inherited-M1/List := result.inherited[class-M1]
  inherited-M2/List := result.inherited[class-M2]
  inherited-B/List := result.inherited[class-B]
  inherited-A/List := result.inherited[class-A]
  expect-equals 0 inherited-M1.size
  expect-equals 1 inherited-M2.size
  expect-equals 0 inherited-B.size
  expect-equals 2 inherited-A.size
  // Note: the order of the inherited members isn't guaranteed.
  foo/inheritance.InheritedMember := inherited-A[0]
  expect-equals "foo" foo.member.name
  expect foo.member.is-method
  bar/inheritance.InheritedMember := inherited-A[1]
  expect-equals "bar" bar.member.name
  expect bar.member.is-method

overridden:
  summaries := create-summaries """
    class A:
      foo --x= --y=:

    class B extends A:
      foo --x= --y:
      foo --x:
      foo:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-A/lsp.Class := classes[0]
  class-B/lsp.Class := classes[1]
  expect-equals "A" class-A.name
  expect-equals "B" class-B.name
  foo-A/lsp.Method := class-A.methods[0]
  foo-Bs/List := class-B.methods
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  expect-equals 0 inherited-A.size
  expect-equals 0 inherited-B.size
  foo-Bs.do: | foo-B/lsp.Method |
    overriding-foo-B/List? := result.shadowing.get (inheritance.ShadowKey class-B foo-B)
    expect-equals 1 overriding-foo-B.size
    expect-equals foo-A overriding-foo-B[0]

mixins-extended-deep:
  summaries := create-summaries """
    mixin M1:

    mixin M2 extends M1:
      foo:
      bar --x:

    class A:
      foo --x=:
      bar --x=:

    class B extends A:

    class C extends B:
      foo:
      bar --x:

    // The depth of M1.foo and M2.bar can not be used once the
    // mixin is in the class chain.
    class D extends C with M2:

    class E extends D:
      foo:
      bar --x:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-M1/lsp.Class := classes[0]
  class-M2/lsp.Class := classes[1]
  class-A/lsp.Class := classes[2]
  class-B/lsp.Class := classes[3]
  class-C/lsp.Class := classes[4]
  class-D/lsp.Class := classes[5]
  class-E/lsp.Class := classes[6]
  inherited-M1/List := result.inherited[class-M1]
  inherited-M2/List := result.inherited[class-M2]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  inherited-C/List := result.inherited[class-C]
  inherited-D/List := result.inherited[class-D]
  inherited-E/List := result.inherited[class-E]
  expect-equals 0 inherited-M1.size
  expect-equals 0 inherited-M2.size
  expect-equals 0 inherited-A.size
  expect-equals 2 inherited-B.size
  expect-equals 2 inherited-C.size
  expect-equals 4 inherited-D.size
  expect-equals 2 inherited-E.size
  foo-M2/lsp.Method := class-M2.methods[0]
  bar-M2/lsp.Method := class-M2.methods[1]
  foo-A/lsp.Method := class-A.methods[0]
  bar-A/lsp.Method := class-A.methods[1]
  foo-C/lsp.Method := class-C.methods[0]
  bar-C/lsp.Method := class-C.methods[1]
  foo-E/lsp.Method := class-E.methods[0]
  bar-E/lsp.Method := class-E.methods[1]
  expect-equals "foo" foo-M2.name
  expect-equals "foo" foo-A.name
  expect-equals "foo" foo-C.name
  expect-equals "foo" foo-E.name
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == foo-A)
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == foo-M2)
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == bar-A)
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == bar-M2)
  overriding-foo-e/List? := result.shadowing.get (inheritance.ShadowKey class-E foo-E)
  overriding-bar-e/List? := result.shadowing.get (inheritance.ShadowKey class-E bar-E)
  expect-equals 2 overriding-foo-e.size
  expect (overriding-foo-e.contains foo-A)
  expect (overriding-foo-e.contains foo-M2)
  expect-equals 2 overriding-bar-e.size
  expect (overriding-bar-e.contains bar-A)
  expect (overriding-bar-e.contains bar-M2)

mixins-many:
  summaries := create-summaries """
    mixin M1:

    mixin M2 extends M1:
      foo:

    mixin M3:
      bar:

    mixin M4:
      baz --x=:

    class A:

    class B extends A:
      foo:

    class C extends B:
      bar --x=:

    class D extends C with M2 M3 M4:

    class E extends D:
      baz:
    """

  result := inheritance.compute summaries
  classes := summaries[TEST-URI].classes
  class-M1/lsp.Class := classes[0]
  class-M2/lsp.Class := classes[1]
  class-M3/lsp.Class := classes[2]
  class-M4/lsp.Class := classes[3]
  class-A/lsp.Class := classes[4]
  class-B/lsp.Class := classes[5]
  class-C/lsp.Class := classes[6]
  class-D/lsp.Class := classes[7]
  class-E/lsp.Class := classes[8]
  inherited-M1/List := result.inherited[class-M1]
  inherited-M2/List := result.inherited[class-M2]
  inherited-M3/List := result.inherited[class-M3]
  inherited-M4/List := result.inherited[class-M4]
  inherited-A/List := result.inherited[class-A]
  inherited-B/List := result.inherited[class-B]
  inherited-C/List := result.inherited[class-C]
  inherited-D/List := result.inherited[class-D]
  inherited-E/List := result.inherited[class-E]
  expect-equals 0 inherited-M1.size
  expect-equals 0 inherited-M2.size
  expect-equals 0 inherited-M3.size
  expect-equals 0 inherited-M4.size
  expect-equals 0 inherited-A.size
  expect-equals 0 inherited-B.size
  expect-equals 1 inherited-C.size
  expect-equals 4 inherited-D.size
  expect-equals 4 inherited-E.size
  foo-M2/lsp.Method := class-M2.methods[0]
  bar-M3/lsp.Method := class-M3.methods[0]
  baz-M4/lsp.Method := class-M4.methods[0]
  foo-B/lsp.Method := class-B.methods[0]
  bar-C/lsp.Method := class-C.methods[0]
  baz-E/lsp.Method := class-E.methods[0]
  expect-equals foo-B (inherited-C.first as inheritance.InheritedMember).member.target
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == foo-M2)
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == bar-M3)
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == baz-M4)
  expect (inherited-D.any: | inherited/inheritance.InheritedMember | inherited.member.target == bar-C)
  expect (inherited-E.any: | inherited/inheritance.InheritedMember | inherited.member.target == foo-M2)
  expect (inherited-E.any: | inherited/inheritance.InheritedMember | inherited.member.target == bar-M3)
  expect (inherited-E.any: | inherited/inheritance.InheritedMember | inherited.member.target == baz-M4)
  expect (inherited-E.any: | inherited/inheritance.InheritedMember | inherited.member.target == bar-C)
