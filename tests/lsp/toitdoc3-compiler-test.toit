// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc-node
import .utils
import system
import system show platform

import host.directory
import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run-client-test args --no-spawn-process: test it
  // Since we used '--no-spawn-process' we must exit 0.
  exit 0

DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
// FILE-PATH and OTHER-PATH must be set up such that 'file.toit' can import other with
// an 'import .other' statement.
FILE-PATH ::= "$DRIVE/tmp/file.toit"
OTHER-PATH ::= "$DRIVE/tmp/other.toit"

build-shape_ method/Method:
  arity := method.parameters.size
  total-block-count := 0
  named-block-count := 0
  names := []
  method.parameters.do:
    if it.is-named: names.add it.name
    if it.is-block:
      total-block-count++
      if it.is-named: named-block-count++
  return Shape
      --arity=arity
      --total-block-count=total-block-count
      --named-block-count=named-block-count
      --is-setter=method.name.ends-with "=" and not method.name.starts-with "operator "
      --names=names

build-name element klass/Class?=null:
  result := klass ? "$(klass.name)." : ""
  result += element.name
  if element.toitdoc:
    sections := element.toitdoc.sections
    if not sections.is-empty:
      statements := sections.first.statements
      if not statements.is-empty:
        expressions := statements.first.expressions
        if not expressions.is-empty:
          expression := expressions.first
          if expression is Text:
            text := (expression as Text).text
            if text.starts-with "@":
              result += text
  return result

build-refs client/LspClient names/List --path=FILE-PATH:
  all-elements-map := {:}
  uri := client.to-uri path
  project-uri := client.server.documents_.project-uri-for --uri=uri
  // Reaching into the private state of the server.
  analyzed-documents := client.server.documents_.analyzed-documents-for --project-uri=project-uri
  document := analyzed-documents.get-existing --uri=uri
  summary := document.summary
  summary.classes.do: |klass|
    all-elements-map[build-name klass] = [ToitdocRef.CLASS, klass]
    klass.statics.do: all-elements-map[build-name it klass] = [ToitdocRef.STATIC-METHOD, it]
    klass.constructors.do: all-elements-map[build-name it klass] = [ToitdocRef.CONSTRUCTOR, it]
    klass.factories.do: all-elements-map[build-name it klass] = [ToitdocRef.FACTORY, it]
    klass.fields.do: all-elements-map[build-name it klass] = [ToitdocRef.FIELD, it]
    klass.methods.do:
      // We don't want to add field getters/setters as the getters would override
      //   the field.
      if not it.is-synthetic:
        all-elements-map[build-name it klass] = [ToitdocRef.METHOD, it]
  summary.functions.do: all-elements-map[build-name it] = [ToitdocRef.GLOBAL-METHOD, it]
  summary.globals.do: all-elements-map[build-name it] = [ToitdocRef.GLOBAL, it]

  return names.map:
    ref := null
    text := null
    if it is string:
      ref = it.trim --left "."
      text = it
    else:
      text = it[0]
      ref = it[1]

    kind-element := all-elements-map[ref]
    kind := kind-element[0]
    element := kind-element[1]
    holder := null
    name := element.name
    if name.ends-with "=" and not name.starts-with "operator ":
      name = name.trim --right "="
    if ref.contains ".":
      parts := ref.split "."
      holder = parts[0]

    if text.starts-with ".": text = element.name

    if element is Method:
      ToitdocRef --kind=kind
          --text=text
          --module-uri=(client.to-uri path)
          --holder=holder
          --name=name
          --shape=build-shape_ (element as Method)
    else:
      ToitdocRef --kind=kind
          --text=text
          --module-uri=(client.to-uri path)
          --holder=holder
          --name=name
          --shape=null

test-toitdoc
    client/LspClient
    [--extract-toitdoc]
    [--build-expected-refs]
    --has-diagnostics/bool=false
    str/string:
  client.send-did-change --path=FILE-PATH str
  if not has-diagnostics:
    diagnostics := client.diagnostics-for --path=FILE-PATH
    diagnostics.do: print it
    expect diagnostics.is-empty
  uri := client.to-uri FILE-PATH
  project-uri := client.server.documents_.project-uri-for --uri=uri
  // Reaching into the private state of the server.
  analyzed-documents := client.server.documents_.analyzed-documents-for --project-uri=project-uri
  document := analyzed-documents.get-existing --uri=uri
  toitdoc := extract-toitdoc.call document.summary
  expected-refs := build-expected-refs.call
  ref-counter := 0
  toitdoc.sections.do:
    it.statements.do:
      if it is Paragraph:
        it.expressions.do:
          if it is ToitdocRef:
            actual/ToitdocRef := it
            expected/ToitdocRef := expected-refs[ref-counter++]
            expect-equals expected.text actual.text
            expect-equals expected.kind actual.kind
            expect-equals expected.module-uri actual.module-uri
            expect-equals expected.holder actual.holder
            expect-equals expected.name actual.name
            if expected.shape:
              expected-shape := expected.shape
              actual-shape := actual.shape
              expect-equals expected-shape.arity actual-shape.arity
              expect-equals expected-shape.total-block-count actual-shape.total-block-count
              expect-equals expected-shape.named-block-count actual-shape.named-block-count
              expect-equals expected-shape.is-setter actual-shape.is-setter
              expect-list-equals expected-shape.names actual-shape.names
            else:
              expect-null actual.shape
  expect-equals expected-refs.size ref-counter

test client/LspClient:
  client.send-did-open --path=OTHER-PATH --text="""
    class OtherClass:
      foo:
    other_fun:
    """
  client.send-did-open --path=FILE-PATH --text=""

  test-toitdoc
      client
      --extract-toitdoc=: it.toitdoc
      --build-expected-refs=: []
      """
      /**
      Module Toitdoc
      */
      """


  test-toitdoc
      client
      --extract-toitdoc=: it.toitdoc
      --build-expected-refs=: build-refs client [
        "ClassA",
        "InterfaceA",
      ]
      """
      /**
      \$ClassA
      \$InterfaceA
      */

      class ClassA:
      interface InterfaceA:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        "ClassB",
        "InterfaceB",
      ]
      """
      /**
      \$ClassB \$InterfaceB
      */
      class A:

      class ClassB:
      interface InterfaceB:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        ".A.foo",
        ".A.bar",
        ".A.gee",
        ".A.statik",
        ".A.static-field",
        ".B.from-super"
      ]
      """
      /**
      \$foo and \$bar and \$gee and \$statik \$static-field \$from-super
      */
      class A extends B:
        foo:
        bar x:
        gee := null
        static statik:
        static static-field := 0

      class B:
        from-super:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.toitdoc
      --build-expected-refs=: build-refs client [
        "A.foo",
        "A.bar",
        "A.gee",
        "A.statik",
        "A.static-field",
      ]
      """
      /**
      \$A.foo and \$A.bar and \$A.gee and \$A.statik \$A.static-field
      */

      class A:
        foo:
        bar x:
        gee := null
        static statik:
        static static-field := 0
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        "A.foo",
        "A.bar",
        "A.gee",
        "A.statik",
        "A.static-field",
      ]
      """
      /**
      \$A.foo and \$A.bar and \$A.gee and \$A.statik \$A.static-field can be accessed
      qualified from the class-toitdoc as well.
      */
      class A:
        foo:
        bar x:
        gee := null
        static statik:
        static static-field := 0
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        "A.named",
        "A.constructor",
        "B.constructor",
        "C.constructor",
      ]
      """
      /**
      \$A.named and \$A.constructor and \$B.constructor and \$C.constructor
      */
      class A:
        constructor x:
        constructor.named:

      class B:
        constructor x: return B.internal_
        constructor.internal_:

      class C:
      """

  // We test `$constructor` in a separate test, as it also needs to
  // build the toitdoc scope (which could otherwise happen because of
  //   other toitdoc references).
  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        ["constructor", "A.constructor"]
      ]
      """
      /**
      \$constructor
      */
      class A:
        constructor x:
        constructor.named:

      class B:
        constructor x: return B.internal_
        constructor.internal_:

      class C:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        ["A.named", "A.named@1"],
        ["A.named x", "A.named@2"],
        ["A.named --foo", "A.named@3"],
        ["A.named [x]", "A.named@4"],
        ["A.named [--foo]", "A.named@5"],
        ["A.foo", "A.foo@1"],
        ["A.foo x", "A.foo@2"],
        ["A.foo --foo", "A.foo@3"],
        ["A.foo [x]", "A.foo@4"],
        ["A.foo [--foo]", "A.foo@5"],
        ["foo", "A.foo@1"],
        ["foo x", "A.foo@2"],
        ["foo --foo", "A.foo@3"],
        ["foo [x]", "A.foo@4"],
        ["foo [--foo]", "A.foo@5"],
        ["B.bar", "B.bar@1"],
        ["B.bar x", "B.bar@2"],
        ["B.bar --foo", "B.bar@3"],
        ["B.bar [x]", "B.bar@4"],
        ["B.bar [--foo]", "B.bar@5"],
        ["A.field-getter", "A.field-getter@1"],
        ["B.field-getter", "B.field-getter@1"],
      ]
      """
      /**
      \$(A.named)
      \$(A.named x)
      \$(A.named --foo)
      \$(A.named [x])
      \$(A.named [--foo])
      \$(A.foo)
      \$(A.foo x)
      \$(A.foo --foo)
      \$(A.foo [x])
      \$(A.foo [--foo])
      \$(foo)
      \$(foo x)
      \$(foo --foo)
      \$(foo [x])
      \$(foo [--foo])
      \$(B.bar)
      \$(B.bar x)
      \$(B.bar --foo)
      \$(B.bar [x])
      \$(B.bar [--foo])
      \$(A.field-getter)
      \$(B.field-getter)
      */
      class A:
        constructor x:
        /**@1*/
        constructor.named:
        /**@2*/
        constructor.named x:
        /**@3*/
        constructor.named --foo:
        /**@4*/
        constructor.named [x]:
        /**@5*/
        constructor.named [--foo]:

        /**@1*/
        foo:
        /**@2*/
        foo x:
        /**@3*/
        foo --foo:
        /**@4*/
        foo [x]:
        /**@5*/
        foo [--foo]:

        /**@1*/
        field-getter := 0

        // Just to make sure the field is resolved correctly.
        field-getter x:

      class B:
        /**@1*/
        bar:
        /**@2*/
        bar x:
        /**@3*/
        bar --foo:
        /**@4*/
        bar [x]:
        /**@5*/
        bar [--foo]:

        /**@1*/
        field-getter := 0

        // Just to make sure the field is resolved correctly.
        field-getter x:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.toitdoc
      --build-expected-refs=: build-refs --path=OTHER-PATH client [
        ["pre.OtherClass", "OtherClass"],
        ["pre.OtherClass.foo", "OtherClass.foo"],
        ["pre.other-fun", "other-fun"],
        ["pre.OtherClass.foo", "OtherClass.foo"],
        ["pre.other-fun", "other-fun"],
      ]
      """
      import .other as pre

      /**
      \$pre.OtherClass
      \$pre.OtherClass.foo
      \$pre.other-fun

      \$(pre.OtherClass.foo)
      \$(pre.other-fun)
      */
      """

  // Make sure we find the correct method when a method is overridden.
  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        ["foo", "A.foo"],
        ["foo", "A.foo"],
        ["A.foo", "A.foo"],
      ]
      """
      /**
      \$foo
      \$(foo)
      \$(A.foo)
      */
      class A extends B:
        foo:

      class B:
        foo:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.toitdoc
      --build-expected-refs=: build-refs client [
        "A.foo=",
        ["A.foo= x", "A.foo="],
        ["B.field=", "B.field"],
        ["B.field= x", "B.field"],
      ]
      """
      /**
      \$A.foo=
      \$(A.foo= x)
      \$B.field=
      \$(B.field= x)
      */

      class A:
        foo= x:

      class B:
        field := null
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        "A.foo=",
        ["A.foo= x", "A.foo="],
        ".A.foo=",
        ["foo= x", "A.foo="],
        ["field=", "A.field"],
        ["field= x", "A.field"],
        ["B.field=", "B.field"],
        ["B.field= x", "B.field"],
      ]
      """
      /**
      \$A.foo=
      \$(A.foo= x)
      \$foo=
      \$(foo= x)
      \$field=
      \$(field= x)
      \$B.field=
      \$(B.field= x)
      */
      class A:
        foo= x:
        field := null

      class B:
        field := null
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        ["A.==", "A.operator =="],
        ["A.<", "A.operator <"],
        ["A.<=", "A.operator <="],
        ["A.>=", "A.operator >="],
        ["A.>", "A.operator >"],
        ["A.+", "A.operator +"],
        ["A.-", "A.operator -"],
        ["A.*", "A.operator *"],
        ["A./", "A.operator /"],
        ["A.%", "A.operator %"],
        ["A.~", "A.operator ~"],
        ["A.&", "A.operator &"],
        ["A.|", "A.operator |"],
        ["A.^", "A.operator ^"],
        ["A.>>", "A.operator >>"],
        ["A.>>>", "A.operator >>>"],
        ["A.<<", "A.operator <<"],
        ["A.[]", "A.operator []"],
        ["A.[]=", "A.operator []="],
        ["==", "A.operator =="],
        ["<", "A.operator <"],
        ["<=", "A.operator <="],
        [">=", "A.operator >="],
        [">", "A.operator >"],
        ["+", "A.operator +"],
        ["-", "A.operator -"],
        ["*", "A.operator *"],
        ["/", "A.operator /"],
        ["%", "A.operator %"],
        ["~", "A.operator ~"],
        ["&", "A.operator &"],
        ["|", "A.operator |"],
        ["^", "A.operator ^"],
        [">>", "A.operator >>"],
        [">>>", "A.operator >>>"],
        ["<<", "A.operator <<"],
        ["[]", "A.operator []"],
        ["[]=", "A.operator []="],
        ["B.==", "B.operator =="],
        ["B.<", "B.operator <"],
        ["B.<=", "B.operator <="],
        ["B.>=", "B.operator >="],
        ["B.>", "B.operator >"],
        ["B.+", "B.operator +"],
        ["B.-", "B.operator -"],
        ["B.*", "B.operator *"],
        ["B./", "B.operator /"],
        ["B.%", "B.operator %"],
        ["B.~", "B.operator ~"],
        ["B.&", "B.operator &"],
        ["B.|", "B.operator |"],
        ["B.^", "B.operator ^"],
        ["B.>>", "B.operator >>"],
        ["B.>>>", "B.operator >>>"],
        ["B.<<", "B.operator <<"],
        ["B.[]", "B.operator []"],
        ["B.[]=", "B.operator []="],
        ["A.== x", "A.operator =="],
        ["A.< x", "A.operator <"],
        ["A.<= x", "A.operator <="],
        ["A.>= x", "A.operator >="],
        ["A.> x", "A.operator >"],
        ["A.+ x", "A.operator +"],
        ["A.- x", "A.operator -"],
        ["A.* x", "A.operator *"],
        ["A./ x", "A.operator /"],
        ["A.% x", "A.operator %"],
        ["A.~", "A.operator ~"],
        ["A.& x", "A.operator &"],
        ["A.| x", "A.operator |"],
        ["A.^ x", "A.operator ^"],
        ["A.>> x", "A.operator >>"],
        ["A.>>> x", "A.operator >>>"],
        ["A.<< x", "A.operator <<"],
        ["A.[] x", "A.operator []"],
        ["A.[]= x y", "A.operator []="],
        ["== x", "A.operator =="],
        ["< x", "A.operator <"],
        ["<= x", "A.operator <="],
        [">= x", "A.operator >="],
        ["> x", "A.operator >"],
        ["+ x", "A.operator +"],
        ["- x", "A.operator -"],
        ["* x", "A.operator *"],
        ["/ x", "A.operator /"],
        ["% x", "A.operator %"],
        ["~", "A.operator ~"],
        ["& x", "A.operator &"],
        ["| x", "A.operator |"],
        ["^ x", "A.operator ^"],
        [">> x", "A.operator >>"],
        [">>> x", "A.operator >>>"],
        ["<< x", "A.operator <<"],
        ["[] x", "A.operator []"],
        ["[]= x y", "A.operator []="],
      ]
      """
      /**
      \$A.==
      \$A.<
      \$A.<=
      \$A.>=
      \$A.>
      \$A.+
      \$A.-
      \$A.*
      \$A./
      \$A.%
      \$A.~
      \$A.&
      \$A.|
      \$A.^
      \$A.>>
      \$A.>>>
      \$A.<<
      \$A.[]
      \$A.[]=
      \$==
      \$<
      \$<=
      \$>=
      \$>
      \$+
      \$-
      \$*
      \$/
      \$%
      \$~
      \$&
      \$|
      \$^
      \$>>
      \$>>>
      \$<<
      \$[]
      \$[]=
      \$B.==
      \$B.<
      \$B.<=
      \$B.>=
      \$B.>
      \$B.+
      \$B.-
      \$B.*
      \$B./
      \$B.%
      \$B.~
      \$B.&
      \$B.|
      \$B.^
      \$B.>>
      \$B.>>>
      \$B.<<
      \$B.[]
      \$B.[]=
      \$(A.== x)
      \$(A.< x)
      \$(A.<= x)
      \$(A.>= x)
      \$(A.> x)
      \$(A.+ x)
      \$(A.- x)
      \$(A.* x)
      \$(A./ x)
      \$(A.% x)
      \$(A.~)
      \$(A.& x)
      \$(A.| x)
      \$(A.^ x)
      \$(A.>> x)
      \$(A.>>> x)
      \$(A.<< x)
      \$(A.[] x)
      \$(A.[]= x y)
      \$(== x)
      \$(< x)
      \$(<= x)
      \$(>= x)
      \$(> x)
      \$(+ x)
      \$(- x)
      \$(* x)
      \$(/ x)
      \$(% x)
      \$(~)
      \$(& x)
      \$(| x)
      \$(^ x)
      \$(>> x)
      \$(>>> x)
      \$(<< x)
      \$([] x)
      \$([]= x y)
      */
      class A:
        operator == other: return true
        operator < other: return true
        operator <= other: return true
        operator >= other: return true
        operator > other: return true
        operator + other:
        operator - other:  // Unary minus is tested elsewhere.
        operator * other:
        operator / other:
        operator % other:
        operator ~:
        operator & other:
        operator | other:
        operator ^ other:
        operator >> amount:
        operator >>> amount:
        operator << amount:
        operator [] i:
        operator []= i val:

      class B:
        operator == other: return true
        operator < other: return true
        operator <= other: return true
        operator >= other: return true
        operator > other: return true
        operator + other:
        operator - other:  // Unary minus is tested elsewhere.
        operator * other:
        operator / other:
        operator % other:
        operator ~:
        operator & other:
        operator | other:
        operator ^ other:
        operator >> amount:
        operator >>> amount:
        operator << amount:
        operator [] i:
        operator []= i val:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.methods.first.toitdoc
      --build-expected-refs=: build-refs client [
        ["super", "B.foo@1"],
        ["super x", "B.foo@2"],
        ["this", "A"]
      ]
      """
      class A extends B:
        /**
        \$super     // Currently goes to the first 'foo' in the super class.
        \$(super x) // Goes to the the 'foo' with the same shape.
        \$this
        */
        foo x:

      class B:
        /**@1*/
        foo:    // No arg.
        /**@2*/
        foo x:  // With arg.
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        ["this", "A"],
      ]
      """
      /**
      \$this
      */
      class A:
      """

  test-toitdoc
      client
      --extract-toitdoc=: it.classes.first.toitdoc
      --build-expected-refs=: build-refs client [
        ["-", "A.operator -"],
        ["-", "B.operator -"],
      ]
      """
      /**
      \$- goes to first matching function, which is the one in A.
      \$(-) goes to function with matching shape: `B.-`.
      */
      class A extends B:
        operator- other:

      class B:
        operator-:
      """

  client.send-did-change --path=FILE-PATH """
      /**
      \$A.from-super is not valid and should yield a warning.
      */

      class A extends B:

      class B:
        from-super:

      """

  expect-equals 1 (client.diagnostics-for --path=FILE-PATH).size

  test-toitdoc
      client
      --extract-toitdoc=: it.toitdoc
      --build-expected-refs=: build-refs client [
        ["foo x y [block1] [block2] --name1 --name2 [--name3] [--name4]", "foo@1"],
        ["foo [block1] [block2] x y --name1 --name2 [--name3] [--name4]", "foo@1"],
        ["foo [block1] [block2] x y [--name4] [--name3] --name2 --name1", "foo@1"],
        ["foo [--name4] [--name3] --name2 --name1 y [block2] x [block2]", "foo@1"],
      ]
      """
      /**
      \$(foo x y [block1] [block2] --name1 --name2 [--name3] [--name4])
      \$(foo [block1] [block2] x y --name1 --name2 [--name3] [--name4])
      \$(foo [block1] [block2] x y [--name4] [--name3] --name2 --name1)
      \$(foo [--name4] [--name3] --name2 --name1 y [block2] x [block2])
      */

      /**@1*/
      foo x y [block1] [block2]  --name1 --name2 [--name3] [--name4]:
      """

  test-toitdoc
      --has-diagnostics
      client
      --extract-toitdoc=: it.toitdoc
      --build-expected-refs=: build-refs client [
        ["foo= x", "foo=@1"],
        ["foo= x y", "foo=@2"],
        ["foo= x [block]", "foo=@3"],
      ]
      """
      /**
      \$(foo= x)
      \$(foo= x y)
      \$(foo= x [block])
      */

      /**@1*/
      foo= x:
      /**@2*/
      foo= x y:
      /**@3*/
      foo= x [block]:
      """
