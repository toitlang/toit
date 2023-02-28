// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc_node
import .utils

import host.directory
import expect show *

OPERATORS_WITH_ASSIGN ::= [
  "==", "<=", ">=", "[]="
]

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run_client_test args --no-spawn_process: test it
  // Since we used '--no-spawn_process' we must exit 0.
  exit 0

DRIVE ::= platform == PLATFORM_WINDOWS ? "c:" : ""
OTHER_PATH ::= "$DRIVE/tmp/other.toit"
FILE_PATH ::= "$DRIVE/tmp/file.toit"

build_shape_ method/Method:
  arity := method.parameters.size
  total_block_count := 0
  named_block_count := 0
  names := []
  method.parameters.do:
    if it.is_named: names.add it.name
    if it.is_block:
      total_block_count++
      if it.is_named: named_block_count++
  return Shape
      --arity=arity
      --total_block_count=total_block_count
      --named_block_count=named_block_count
      --is_setter=method.name.ends_with "=" and not OPERATORS_WITH_ASSIGN.contains method.name
      --names=names

build_name element klass/Class?=null:
  result := klass ? "$(klass.name)." : ""
  result += element.name
  if element.toitdoc:
    sections := element.toitdoc.sections
    if not sections.is_empty:
      statements := sections.first.statements
      if not statements.is_empty:
        expressions := statements.first.expressions
        if not expressions.is_empty:
          expression := expressions.first
          if expression is Text:
            text := (expression as Text).text
            if text.starts_with "@":
              result += text
  return result

build_refs client/LspClient names/List --path=FILE_PATH:
  all_elements_map := {:}
  document := client.server.documents_.get_existing_document --path=path
  summary := document.summary
  summary.classes.do: |klass|
    all_elements_map[build_name klass] = [ToitdocRef.CLASS, klass]
    klass.statics.do: all_elements_map[build_name it klass] = [ToitdocRef.STATIC_METHOD, it]
    klass.constructors.do: all_elements_map[build_name it klass] = [ToitdocRef.CONSTRUCTOR, it]
    klass.factories.do: all_elements_map[build_name it klass] = [ToitdocRef.FACTORY, it]
    klass.fields.do: all_elements_map[build_name it klass] = [ToitdocRef.FIELD, it]
    klass.methods.do:
      // We don't want to add field getters/setters as the getters would override
      //   the field.
      if not it.is_synthetic:
        all_elements_map[build_name it klass] = [ToitdocRef.METHOD, it]
  summary.functions.do: all_elements_map[build_name it] = [ToitdocRef.GLOBAL_METHOD, it]
  summary.globals.do: all_elements_map[build_name it] = [ToitdocRef.GLOBAL, it]

  return names.map:
    ref := null
    text := null
    if it is string:
      ref = it.trim --left "."
      text = it
    else:
      text = it[0]
      ref = it[1]

    kind_element := all_elements_map[ref]
    kind := kind_element[0]
    element := kind_element[1]
    holder := null
    name := element.name
    if name.ends_with "=" and not OPERATORS_WITH_ASSIGN.contains name:
      name = name.trim --right "="
    if ref.contains ".":
      parts := ref.split "."
      holder = parts[0]

    if text.starts_with ".": text = element.name

    if element is Method:
      ToitdocRef --kind=kind
          --text=text
          --module_uri=(client.to_uri path)
          --holder=holder
          --name=name
          --shape=build_shape_ (element as Method)
    else:
      ToitdocRef --kind=kind
          --text=text
          --module_uri=(client.to_uri path)
          --holder=holder
          --name=name
          --shape=null

test_toitdoc
    client/LspClient
    [--extract_toitdoc]
    [--build_expected_refs]
    --has_diagnostics/bool=false
    str/string:
  client.send_did_change --path=FILE_PATH str
  if not has_diagnostics:
    diagnostics := client.diagnostics_for --path=FILE_PATH
    diagnostics.do: print it
    expect diagnostics.is_empty
  // Reaching into the private state of the server.
  document := client.server.documents_.get_existing_document --path=FILE_PATH
  toitdoc := extract_toitdoc.call document.summary
  expected_refs := build_expected_refs.call
  ref_counter := 0
  toitdoc.sections.do:
    it.statements.do:
      if it is Paragraph:
        it.expressions.do:
          if it is ToitdocRef:
            actual := it
            expected := expected_refs[ref_counter++]
            expect_equals expected.text actual.text
            expect_equals expected.kind actual.kind
            expect_equals expected.module_uri actual.module_uri
            expect_equals expected.holder actual.holder
            expect_equals expected.name actual.name
            if expected.shape:
              expected_shape := expected.shape
              actual_shape := actual.shape
              expect_equals expected_shape.arity actual_shape.arity
              expect_equals expected_shape.total_block_count actual_shape.total_block_count
              expect_equals expected_shape.named_block_count actual_shape.named_block_count
              expect_equals expected_shape.is_setter actual_shape.is_setter
              expect_list_equals expected_shape.names actual_shape.names
            else:
              expect_null actual.shape
  expect_equals expected_refs.size ref_counter

test client/LspClient:
  client.send_did_open --path=OTHER_PATH --text="""
    class OtherClass:
      foo:
    other_fun:
    """
  client.send_did_open --path=FILE_PATH --text=""

  test_toitdoc
      client
      --extract_toitdoc=: it.toitdoc
      --build_expected_refs=: []
      """
      /**
      Module Toitdoc
      */
      """


  test_toitdoc
      client
      --extract_toitdoc=: it.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
        ".A.foo",
        ".A.bar",
        ".A.gee",
        ".A.statik",
        ".A.static_field",
        ".B.from_super"
      ]
      """
      /**
      \$foo and \$bar and \$gee and \$statik \$static_field \$from_super
      */
      class A extends B:
        foo:
        bar x:
        gee := null
        static statik:
        static static_field := 0

      class B:
        from_super:
      """

  test_toitdoc
      client
      --extract_toitdoc=: it.toitdoc
      --build_expected_refs=: build_refs client [
        "A.foo",
        "A.bar",
        "A.gee",
        "A.statik",
        "A.static_field",
      ]
      """
      /**
      \$A.foo and \$A.bar and \$A.gee and \$A.statik \$A.static_field
      */

      class A:
        foo:
        bar x:
        gee := null
        static statik:
        static static_field := 0
      """

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
        "A.foo",
        "A.bar",
        "A.gee",
        "A.statik",
        "A.static_field",
      ]
      """
      /**
      \$A.foo and \$A.bar and \$A.gee and \$A.statik \$A.static_field can be accessed
      qualified from the class-toitdoc as well.
      */
      class A:
        foo:
        bar x:
        gee := null
        static statik:
        static static_field := 0
      """

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
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
  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
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
        ["A.field_getter", "A.field_getter@1"],
        ["B.field_getter", "B.field_getter@1"],
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
      \$(A.field_getter)
      \$(B.field_getter)
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
        field_getter := 0

        // Just to make sure the field is resolved correctly.
        field_getter x:

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
        field_getter := 0

        // Just to make sure the field is resolved correctly.
        field_getter x:
      """

  // Make sure we can reference the other path with a relative import.
  assert: FILE_PATH == "/tmp/file.toit" and OTHER_PATH == "/tmp/other.toit"
  test_toitdoc
      client
      --extract_toitdoc=: it.toitdoc
      --build_expected_refs=: build_refs --path=OTHER_PATH client [
        ["pre.OtherClass", "OtherClass"],
        ["pre.OtherClass.foo", "OtherClass.foo"],
        ["pre.other_fun", "other_fun"],
        ["pre.OtherClass.foo", "OtherClass.foo"],
        ["pre.other_fun", "other_fun"],
      ]
      """
      import .other as pre

      /**
      \$pre.OtherClass
      \$pre.OtherClass.foo
      \$pre.other_fun

      \$(pre.OtherClass.foo)
      \$(pre.other_fun)
      */
      """

  // Make sure we find the correct method when a method is overridden.
  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      client
      --extract_toitdoc=: it.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
        "A.==",
        "A.<",
        "A.<=",
        "A.>=",
        "A.>",
        "A.+",
        "A.-",
        "A.*",
        "A./",
        "A.%",
        "A.~",
        "A.&",
        "A.|",
        "A.^",
        "A.>>",
        "A.>>>",
        "A.<<",
        "A.[]",
        "A.[]=",
        ".A.==",
        ".A.<",
        ".A.<=",
        ".A.>=",
        ".A.>",
        ".A.+",
        ".A.-",
        ".A.*",
        ".A./",
        ".A.%",
        ".A.~",
        ".A.&",
        ".A.|",
        ".A.^",
        ".A.>>",
        ".A.>>>",
        ".A.<<",
        ".A.[]",
        ".A.[]=",
        "B.==",
        "B.<",
        "B.<=",
        "B.>=",
        "B.>",
        "B.+",
        "B.-",
        "B.*",
        "B./",
        "B.%",
        "B.~",
        "B.&",
        "B.|",
        "B.^",
        "B.>>",
        "B.>>>",
        "B.<<",
        "B.[]",
        "B.[]=",
        ["A.== x", "A.=="],
        ["A.< x", "A.<"],
        ["A.<= x", "A.<="],
        ["A.>= x", "A.>="],
        ["A.> x", "A.>"],
        ["A.+ x", "A.+"],
        ["A.- x", "A.-"],
        ["A.* x", "A.*"],
        ["A./ x", "A./"],
        ["A.% x", "A.%"],
        ["A.~", "A.~"],
        ["A.& x", "A.&"],
        ["A.| x", "A.|"],
        ["A.^ x", "A.^"],
        ["A.>> x", "A.>>"],
        ["A.>>> x", "A.>>>"],
        ["A.<< x", "A.<<"],
        ["A.[] x", "A.[]"],
        ["A.[]= x y", "A.[]="],
        ["== x", "A.=="],
        ["< x", "A.<"],
        ["<= x", "A.<="],
        [">= x", "A.>="],
        ["> x", "A.>"],
        ["+ x", "A.+"],
        ["- x", "A.-"],
        ["* x", "A.*"],
        ["/ x", "A./"],
        ["% x", "A.%"],
        ["~", "A.~"],
        ["& x", "A.&"],
        ["| x", "A.|"],
        ["^ x", "A.^"],
        [">> x", "A.>>"],
        [">>> x", "A.>>>"],
        ["<< x", "A.<<"],
        ["[] x", "A.[]"],
        ["[]= x y", "A.[]="],
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
        operator == other:
        operator < other:
        operator <= other:
        operator >= other:
        operator > other:
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
        operator == other:
        operator < other:
        operator <= other:
        operator >= other:
        operator > other:
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

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.methods.first.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
        ["this", "A"],
      ]
      """
      /**
      \$this
      */
      class A:
      """

  test_toitdoc
      client
      --extract_toitdoc=: it.classes.first.toitdoc
      --build_expected_refs=: build_refs client [
        ".A.-",
        ["-", "B.-"],
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

  client.send_did_change --path=FILE_PATH """
      /**
      \$A.from_super is not valid and should yield a warning.
      */

      class A extends B:

      class B:
        from_super:

      """

  expect_equals 1 (client.diagnostics_for --path=FILE_PATH).size

  test_toitdoc
      client
      --extract_toitdoc=: it.toitdoc
      --build_expected_refs=: build_refs client [
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

  test_toitdoc
      --has_diagnostics
      client
      --extract_toitdoc=: it.toitdoc
      --build_expected_refs=: build_refs client [
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
